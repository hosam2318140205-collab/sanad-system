-- ترقية مشروع قائم: نفّذ هذا الملف مرة واحدة في SQL Editor (مولَّد من supabase/migrations/0008_purchase_advisor.sql)
-- لا تنفذه على مشروع جديد — المشروع الجديد يستخدم 01_all_migrations.sql الذي يتضمنه.
begin;
-- =====================================================================
-- مساعد الشراء الذكي (المرحلة الأولى — حسابات قابلة للتفسير، بدون AI خارجي)
--   • تحليل كل صنف (منتج + مقاس + لون) من المبيعات والمرتجعات الفعلية
--   • متوسط بيع يومي مرجّح، أيام التغطية، نقطة إعادة الطلب، الكمية المقترحة
--   • الراكد: أيام منذ آخر بيع + قيمة المخزون الراكد
--   • تحويل التوصيات المختارة إلى مسودة أمر شراء
-- إضافة فقط: لا تغيير على الجداول أو الدوال السابقة، ولا على منطق المخزون أو البيع
-- =====================================================================

-- ---------------------------------------------------------------------
-- التحليل
--   صافي المباع في نافذة = الكميات المباعة − المرتجعة خلال النافذة (لا يقل عن صفر)
--   معدل النافذة = صافي المباع ÷ min(طول النافذة، عمر الصنف بالأيام)
--       (حتى لا يُظلم صنف أُضيف قبل أيام)
--   متوسط البيع اليومي = 20% معدل 7 أيام + 50% معدل 30 يوم + 30% معدل 90 يوم
--   نقطة إعادة الطلب = ⌈المتوسط × (مدة التوريد + أيام الأمان)⌉
--   المستوى المستهدف  = ⌈المتوسط × (مدة التوريد + أيام الأمان + أيام التغطية المطلوبة)⌉
--   المقترح = المستهدف − (المخزون + الكمية في أوامر شراء مفتوحة)
--             فقط إذا كان (المخزون + المفتوح) ≤ نقطة إعادة الطلب
-- ---------------------------------------------------------------------
create or replace function public.purchase_advisor(
  p_lead_days integer default 7,
  p_cover_days integer default 30,
  p_safety_days integer default 7
)
returns table (
  variant_id uuid,
  product_id uuid,
  product_name text,
  category_name text,
  size text,
  color text,
  sku text,
  barcode text,
  is_active boolean,
  stock integer,
  on_order integer,
  unit_cost numeric,
  unit_price numeric,
  sold_7 integer,
  sold_30 integer,
  sold_90 integer,
  age_days integer,
  avg_daily numeric,
  cover_days numeric,
  reorder_point integer,
  target_qty integer,
  suggested_qty integer,
  last_sale_at timestamptz,
  idle_days integer,
  supplier_id uuid,
  supplier_name text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_lead_days < 0 or p_cover_days < 1 or p_safety_days < 0
     or p_lead_days > 365 or p_cover_days > 365 or p_safety_days > 365 then
    raise exception 'قيم غير صحيحة: مدة التوريد والأمان 0–365، والتغطية 1–365 يوماً';
  end if;

  return query
  with sold as (
    select si.variant_id,
           sum(si.qty) filter (where s.created_at >= now() - interval '7 days')  as q7,
           sum(si.qty) filter (where s.created_at >= now() - interval '30 days') as q30,
           sum(si.qty) as q90
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
     where s.created_at >= now() - interval '90 days'
     group by si.variant_id
  ),
  returned as (
    select ri.variant_id,
           sum(ri.qty) filter (where r.created_at >= now() - interval '7 days')  as q7,
           sum(ri.qty) filter (where r.created_at >= now() - interval '30 days') as q30,
           sum(ri.qty) as q90
      from public.return_items ri
      join public.returns r on r.id = ri.return_id
     where r.created_at >= now() - interval '90 days'
     group by ri.variant_id
  ),
  last_sale as (
    select si.variant_id, max(s.created_at) as at
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
     group by si.variant_id
  ),
  open_po as (
    select pi.variant_id, sum(pi.qty)::integer as qty
      from public.purchase_items pi
      join public.purchase_orders po on po.id = pi.purchase_id
     where po.status in ('draft', 'ordered')
     group by pi.variant_id
  ),
  last_supplier as (
    select distinct on (pi.variant_id) pi.variant_id, po.supplier_id
      from public.purchase_items pi
      join public.purchase_orders po on po.id = pi.purchase_id
     where po.status <> 'cancelled'
     order by pi.variant_id, coalesce(po.received_at, po.created_at) desc
  ),
  base as (
    select v.id, v.product_id, p.name as pname, c.name as cname, v.size, v.color, v.sku, v.barcode,
           (v.is_active and p.is_active) as active,
           v.stock_qty,
           coalesce(o.qty, 0) as on_order,
           coalesce(vc.cost_price, 0) as cost,
           coalesce(v.price, p.base_price) as price,
           greatest(coalesce(sd.q7, 0) - coalesce(rt.q7, 0), 0)::integer as n7,
           greatest(coalesce(sd.q30, 0) - coalesce(rt.q30, 0), 0)::integer as n30,
           greatest(coalesce(sd.q90, 0) - coalesce(rt.q90, 0), 0)::integer as n90,
           greatest(ceil(extract(epoch from now() - v.created_at) / 86400), 1)::integer as age,
           ls.at as last_at,
           lsu.supplier_id
      from public.product_variants v
      join public.products p on p.id = v.product_id
      left join public.categories c on c.id = p.category_id
      left join public.variant_costs vc on vc.variant_id = v.id
      left join sold sd on sd.variant_id = v.id
      left join returned rt on rt.variant_id = v.id
      left join last_sale ls on ls.variant_id = v.id
      left join open_po o on o.variant_id = v.id
      left join last_supplier lsu on lsu.variant_id = v.id
     where (v.is_active and p.is_active) or v.stock_qty <> 0
  ),
  rated as (
    select b.*,
           round(
             0.2 * b.n7 / least(7, b.age)::numeric
           + 0.5 * b.n30 / least(30, b.age)::numeric
           + 0.3 * b.n90 / least(90, b.age)::numeric, 3) as avg_d
      from base b
  ),
  planned as (
    select r.*,
           ceil(r.avg_d * (p_lead_days + p_safety_days))::integer as rop,
           ceil(r.avg_d * (p_lead_days + p_safety_days + p_cover_days))::integer as target
      from rated r
  )
  select pl.id, pl.product_id, pl.pname, pl.cname, pl.size, pl.color, pl.sku, pl.barcode, pl.active,
         pl.stock_qty, pl.on_order, pl.cost, pl.price,
         pl.n7, pl.n30, pl.n90, pl.age,
         pl.avg_d,
         case when pl.avg_d > 0 then round(greatest(pl.stock_qty, 0) / pl.avg_d, 1) end,
         pl.rop,
         pl.target,
         case
           when pl.active and pl.avg_d > 0 and greatest(pl.stock_qty, 0) + pl.on_order <= pl.rop
             then greatest(pl.target - greatest(pl.stock_qty, 0) - pl.on_order, 0)
           else 0
         end,
         pl.last_at,
         greatest(floor(extract(epoch from now() - coalesce(pl.last_at, (
           -- لم يُبع أبداً: منذ دخوله المخزون (أول حركة) أو إنشائه
           select min(m.created_at) from public.stock_movements m where m.variant_id = pl.id and m.qty_change > 0
         ), (select v2.created_at from public.product_variants v2 where v2.id = pl.id))) / 86400), 0)::integer,
         pl.supplier_id,
         su.name
    from planned pl
    left join public.suppliers su on su.id = pl.supplier_id
   order by pl.pname, pl.size nulls first, pl.color nulls first;
end;
$$;

-- ---------------------------------------------------------------------
-- تحويل التوصيات إلى مسودة أمر شراء لمورد واحد
--   p_items: [{"variant_id": "...", "qty": 5}, ...] — التكلفة من آخر تكلفة مسجلة للصنف
--   تُنشأ كمسودة فقط؛ الاستلام وتحديث المخزون يتمان من شاشة المشتريات كالمعتاد
-- ---------------------------------------------------------------------
create or replace function public.create_purchase_draft(
  p_supplier_id uuid,
  p_items jsonb,
  p_notes text default null
)
returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if not exists (select 1 from public.suppliers where id = p_supplier_id and is_active) then
    raise exception 'المورد غير موجود أو غير نشط';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'لا توجد أصناف';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) e
     where coalesce((e->>'qty')::integer, 0) <= 0
        or not exists (select 1 from public.product_variants v where v.id = (e->>'variant_id')::uuid)
  ) then
    raise exception 'صنف غير موجود أو كمية غير صحيحة';
  end if;

  insert into public.purchase_orders (po_no, supplier_id, status, notes)
  values (public.next_po_no(), p_supplier_id, 'draft',
          coalesce(nullif(trim(p_notes), ''), 'مسودة من مساعد الشراء الذكي'))
  returning id into v_id;

  insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost)
  select v_id, x.variant_id, x.qty, coalesce(vc.cost_price, 0)
    from (
      select (e->>'variant_id')::uuid as variant_id, sum((e->>'qty')::integer)::integer as qty
        from jsonb_array_elements(p_items) e
       group by 1
    ) x
    left join public.variant_costs vc on vc.variant_id = x.variant_id;
  -- الإجماليات يحسبها trigger purchase_items_totals الموجود

  return v_id;
end;
$$;

revoke execute on function public.purchase_advisor(integer, integer, integer) from public, anon;
revoke execute on function public.create_purchase_draft(uuid, jsonb, text) from public, anon;
grant execute on function public.purchase_advisor(integer, integer, integer) to authenticated;
grant execute on function public.create_purchase_draft(uuid, jsonb, text) to authenticated;
commit;
