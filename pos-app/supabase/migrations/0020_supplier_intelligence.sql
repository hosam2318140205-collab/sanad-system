-- =====================================================================
-- 0020 ذكاء الموردين ولوحة المشتريات (PR #9 — المرحلة 4)
--   • تاريخ الأسعار من الفواتير المرحّلة: سعر الفاتورة + نصيب القطعة من تكاليف الوصول (التكلفة الواصلة)
--     (محسوب من المستندات مباشرة فلا يحتاج مزامنة)
--   • كتالوج المورد (اختياري): رمز الصنف عنده، الحد الأدنى، مضاعف العبوة، السعر المتفق عليه، مدة التوريد
--   • تقييم المورد لكل صنف: التكلفة الواصلة 50% + مدة التوريد الفعلية 20% + نسبة التوريد 15% + الجودة (1 − المرتجع) 15%
--     الأوزان من الإعدادات. مورد بلا مشتريات سابقة لهذا الموديل = «بيانات غير كافية» ولا يُرشَّح تلقائياً
--   • suggest_supplier مع «لماذا؟» بالأرقام، ومقارنة الأسعار، ولوحة المستحقات والمشتريات
--   • التكامل مع #8: مركز القرارات يقدّم النقل الداخلي، والمتبقي فقط يُشترى من المورد المقترح
--     create_purchase_drafts_by_supplier تجمّع المسودات حسب المورد وموقع الاستلام (بمفتاح منع تكرار)
--   • مساعد الشراء (0008) يحتسب المتبقي من أوامر الشراء المستلمة جزئياً
-- =====================================================================

alter table public.store_settings
  add column supplier_weight_price integer not null default 50 check (supplier_weight_price between 0 and 100),
  add column supplier_weight_lead integer not null default 20 check (supplier_weight_lead between 0 and 100),
  add column supplier_weight_fill integer not null default 15 check (supplier_weight_fill between 0 and 100),
  add column supplier_weight_quality integer not null default 15 check (supplier_weight_quality between 0 and 100),
  add constraint supplier_weights_sum check (supplier_weight_price + supplier_weight_lead + supplier_weight_fill + supplier_weight_quality = 100);

create table public.supplier_items (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id) on delete cascade,
  supplier_sku text,
  agreed_cost numeric(12,2) check (agreed_cost is null or agreed_cost >= 0),
  min_order_qty integer check (min_order_qty is null or min_order_qty > 0),
  pack_size integer check (pack_size is null or pack_size > 0),
  lead_time_days integer check (lead_time_days is null or lead_time_days between 0 and 365),
  is_preferred boolean not null default false,
  updated_at timestamptz not null default now(),
  unique (supplier_id, variant_id)
);
create index supplier_items_variant_idx on public.supplier_items (variant_id);
create trigger supplier_items_touch before update on public.supplier_items
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- نقاط السعر: كل سطر فاتورة مرحّل + نصيب القطعة من تكاليف الوصول غير الملغاة
-- ---------------------------------------------------------------------
create or replace function public._supplier_price_points()
returns table (supplier_id uuid, variant_id uuid, product_id uuid, invoice_id uuid, invoice_date date, qty integer,
               unit_cost numeric, landed_unit numeric, seq text)
language sql stable security definer set search_path = public as $$
  select i.supplier_id, l.variant_id, v.product_id, i.id, i.invoice_date, l.qty, l.unit_cost,
         round(l.unit_cost + coalesce((select sum(a.amount) from public.landed_cost_allocations a
                                         join public.landed_cost_vouchers lv on lv.id = a.voucher_id and lv.status = 'posted'
                                        where a.receipt_item_id = l.receipt_item_id), 0) / gi.qty, 2),
         -- ترتيب زمني ثابت حتى لفاتورتين في نفس اليوم
         to_char(i.invoice_date, 'YYYYMMDD') || to_char(i.posted_at, 'HH24MISSUS') || i.doc_no
    from public.supplier_invoice_items l
    join public.supplier_invoices i on i.id = l.invoice_id and i.status in ('posted', 'partially_paid', 'paid') and i.kind = 'purchase'
    join public.goods_receipt_items gi on gi.id = l.receipt_item_id
    join public.product_variants v on v.id = l.variant_id
$$;

create or replace function public.supplier_price_history(p_variant uuid default null, p_product uuid default null, p_days integer default 365)
returns table (supplier_id uuid, supplier_name text, variant_id uuid, sku text, invoice_id uuid, doc_no text, invoice_date date,
               qty integer, unit_cost numeric, landed_unit numeric, change_pct numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
    select p.supplier_id, s.name, p.variant_id, v.sku, p.invoice_id, i.doc_no, p.invoice_date, p.qty, p.unit_cost, p.landed_unit,
           round((p.unit_cost - lag(p.unit_cost) over w) / nullif(lag(p.unit_cost) over w, 0) * 100, 1)
      from public._supplier_price_points() p
      join public.suppliers s on s.id = p.supplier_id
      join public.product_variants v on v.id = p.variant_id
      join public.supplier_invoices i on i.id = p.invoice_id
     where (p_variant is null or p.variant_id = p_variant) and (p_product is null or p.product_id = p_product)
       and p.invoice_date >= current_date - p_days
    window w as (partition by p.supplier_id, p.variant_id order by p.seq)
     order by p.invoice_date desc, s.name;
end;
$$;

-- ---------------------------------------------------------------------
-- أداء المورد (على مستوى المورد، آخر 365 يوماً)
-- ---------------------------------------------------------------------
create or replace function public._supplier_performance()
returns table (supplier_id uuid, lead_days numeric, fill_rate numeric, return_rate numeric, price_adherence numeric,
               pos integer, receipts integer)
language sql stable security definer set search_path = public as $$
  with po as (
    select po.supplier_id, po.id, coalesce(po.approved_at, po.created_at) as sent_at,
           (select min(gr.received_at) from public.goods_receipts gr where gr.purchase_order_id = po.id and not gr.is_historical) as first_in,
           (select sum(qty) from public.purchase_items where purchase_id = po.id) as ordered,
           (select sum(qty_received) from public.purchase_items where purchase_id = po.id) as received,
           (select sum(qty_returned) from public.purchase_items where purchase_id = po.id) as returned
      from public.purchase_orders po
     where po.status::text in ('ordered', 'partially_received', 'received', 'closed')
       and coalesce(po.approved_at, po.created_at) >= now() - interval '365 days'
  ),
  adh as (
    select i.supplier_id, avg(abs(l.unit_cost - l.po_unit_cost) / nullif(l.po_unit_cost, 0) * 100) as dev
      from public.supplier_invoice_items l join public.supplier_invoices i on i.id = l.invoice_id
     where i.status in ('posted', 'partially_paid', 'paid') and l.po_unit_cost is not null and i.invoice_date >= current_date - 365
     group by 1
  )
  select po.supplier_id,
         round(avg(extract(epoch from po.first_in - po.sent_at) / 86400) filter (where po.first_in is not null), 1),
         round(sum(po.received)::numeric / nullif(sum(po.ordered) filter (where po.first_in is not null or po.received > 0), 0), 3),
         round(coalesce(sum(po.returned), 0)::numeric / nullif(sum(po.received), 0), 3),
         round(max(a.dev), 2),
         count(*)::integer, count(po.first_in)::integer
    from po left join adh a on a.supplier_id = po.supplier_id
   group by po.supplier_id
$$;

-- ---------------------------------------------------------------------
-- تقييم المرشحين لكل صنف
-- ---------------------------------------------------------------------
create or replace function public.supplier_scores(p_variants uuid[])
returns table (variant_id uuid, supplier_id uuid, supplier_name text, cost numeric, cost_basis text, cost_points integer,
               last_cost numeric, last_date date, lead_days numeric, fill_rate numeric, return_rate numeric,
               score numeric, rank integer, sufficient boolean, why jsonb)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  st public.store_settings;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select * into st from public.store_settings where id = 1;
  return query
  with vv as (
    select v.id as variant_id, v.product_id from public.product_variants v where v.id = any(p_variants)
  ),
  pts as (select * from public._supplier_price_points() where invoice_date >= current_date - 180),
  cand as (
    select distinct vv.variant_id, x.supplier_id from vv
      join lateral (
        select p.supplier_id from public._supplier_price_points() p
         where p.invoice_date >= current_date - 365 and (p.variant_id = vv.variant_id or p.product_id = vv.product_id)
        union
        select si.supplier_id from public.supplier_items si where si.variant_id = vv.variant_id
      ) x on true
  ),
  base as (
    select c.variant_id, c.supplier_id, s.name,
           -- التكلفة الواصلة: متوسط مرجّح للصنف نفسه (180 يوماً) ← ثم الموديل ← ثم السعر المتفق عليه
           coalesce(
             (select round(sum(p.landed_unit * p.qty) / sum(p.qty), 2) from pts p where p.supplier_id = c.supplier_id and p.variant_id = c.variant_id),
             (select round(sum(p.landed_unit * p.qty) / sum(p.qty), 2) from pts p join vv on vv.variant_id = c.variant_id
               where p.supplier_id = c.supplier_id and p.product_id = vv.product_id),
             (select si.agreed_cost from public.supplier_items si where si.supplier_id = c.supplier_id and si.variant_id = c.variant_id)) as cost,
           case when exists (select 1 from pts p where p.supplier_id = c.supplier_id and p.variant_id = c.variant_id) then 'variant'
                when exists (select 1 from pts p join vv on vv.variant_id = c.variant_id where p.supplier_id = c.supplier_id and p.product_id = vv.product_id) then 'model'
                when exists (select 1 from public.supplier_items si where si.supplier_id = c.supplier_id and si.variant_id = c.variant_id and si.agreed_cost is not null) then 'agreed'
                else 'none' end as basis,
           (select count(*)::integer from pts p where p.supplier_id = c.supplier_id and p.variant_id = c.variant_id) as npts,
           (select p.landed_unit from public._supplier_price_points() p where p.supplier_id = c.supplier_id and p.variant_id = c.variant_id
             order by p.seq desc limit 1) as last_cost,
           (select max(p.invoice_date) from public._supplier_price_points() p where p.supplier_id = c.supplier_id and p.variant_id = c.variant_id) as last_date,
           coalesce(pf.lead_days, (select si.lead_time_days from public.supplier_items si where si.supplier_id = c.supplier_id and si.variant_id = c.variant_id),
                    s.lead_time_days) as lead,
           coalesce(pf.fill_rate, 1) as fill, coalesce(pf.return_rate, 0) as ret,
           exists (select 1 from public._supplier_price_points() p join vv on vv.variant_id = c.variant_id
                    where p.supplier_id = c.supplier_id and (p.variant_id = c.variant_id or p.product_id = vv.product_id)) as sufficient
      from cand c
      join public.suppliers s on s.id = c.supplier_id and s.is_active
      left join public._supplier_performance() pf on pf.supplier_id = c.supplier_id
  ),
  mins as (
    select variant_id, min(cost) filter (where cost > 0) as min_cost, min(lead) filter (where lead is not null) as min_lead
      from base where sufficient group by 1
  ),
  scored as (
    select b.*,
           round(st.supplier_weight_price * coalesce(m.min_cost / nullif(b.cost, 0), 0)
               + st.supplier_weight_lead * case when b.lead is null then 0.5 when b.lead <= 0 or m.min_lead <= 0 then 1
                                                else least(m.min_lead / b.lead, 1) end
               + st.supplier_weight_fill * least(b.fill, 1)
               + st.supplier_weight_quality * greatest(1 - b.ret, 0), 1) as sc
      from base b left join mins m on m.variant_id = b.variant_id
  )
  select s.variant_id, s.supplier_id, s.name, s.cost, s.basis, s.npts, s.last_cost, s.last_date, s.lead, s.fill, s.ret,
         case when s.sufficient then s.sc end,
         case when s.sufficient then (rank() over (partition by s.variant_id, s.sufficient order by s.sc desc, s.cost asc nulls last))::integer end,
         s.sufficient,
         jsonb_build_object('cost', s.cost, 'cost_basis', s.basis, 'price_points', s.npts, 'last_cost', s.last_cost,
                            'lead_days', s.lead, 'fill_rate', s.fill, 'return_rate', s.ret,
                            'weights', jsonb_build_object('price', st.supplier_weight_price, 'lead', st.supplier_weight_lead,
                                                          'fill', st.supplier_weight_fill, 'quality', st.supplier_weight_quality))
    from scored s
   order by s.variant_id, s.sufficient desc, s.sc desc nulls last;
end;
$$;

-- الأنسب لكل صنف + «لماذا؟» مقارنةً بالبديل الأفضل التالي
create or replace function public.suggest_suppliers(p_variants uuid[])
returns table (variant_id uuid, supplier_id uuid, supplier_name text, cost numeric, lead_days numeric, fill_rate numeric,
               score numeric, reason text, alternatives jsonb)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with s as (select * from public.supplier_scores(p_variants)),
  best as (select * from s where rank = 1),
  second as (select distinct on (variant_id) * from s where sufficient and rank > 1 order by variant_id, rank, cost)
  select b.variant_id, b.supplier_id, b.supplier_name, b.cost, b.lead_days, b.fill_rate, b.score,
         format('«%s»: %s ر.س للقطعة واصلة (%s)، يورّد خلال %s، ويسلّم %s%% من المطلوب، مرتجعاته %s%%.%s',
                b.supplier_name, b.cost,
                case b.cost_basis when 'variant' then format('متوسط %s فاتورة خلال 180 يوماً', b.cost_points)
                                  when 'model' then 'من أسعار نفس الموديل' else 'السعر المتفق عليه' end,
                coalesce(b.lead_days::text || ' يوم', 'مدة غير معروفة'),
                round(coalesce(b.fill_rate, 1) * 100), round(coalesce(b.return_rate, 0) * 100, 1),
                case when n.supplier_id is null then ' لا يوجد مورد بديل ببيانات كافية.'
                     else format(' مقارنةً بـ«%s»: %s ر.س (%s%s%%)%s — التقييم %s مقابل %s.',
                                 n.supplier_name, n.cost,
                                 case when n.cost >= b.cost then '+' else '' end,
                                 round((n.cost - b.cost) / nullif(b.cost, 0) * 100, 1),
                                 case when n.lead_days is not null and b.lead_days is not null and n.lead_days < b.lead_days
                                      then format(' رغم أنه أسرع بـ%s يوم', b.lead_days - n.lead_days) else '' end,
                                 b.score, n.score) end),
         coalesce((select jsonb_agg(jsonb_build_object('supplier_id', x.supplier_id, 'name', x.supplier_name, 'cost', x.cost,
                                                       'lead_days', x.lead_days, 'score', x.score, 'sufficient', x.sufficient) order by x.sufficient desc, x.score desc nulls last)
                     from s x where x.variant_id = b.variant_id and x.supplier_id <> b.supplier_id), '[]'::jsonb)
    from best b left join second n on n.variant_id = b.variant_id;
end;
$$;

create or replace function public.supplier_price_comparison(p_product uuid)
returns table (variant_id uuid, sku text, size text, color text, supplier_id uuid, supplier_name text,
               last_cost numeric, avg_landed_180 numeric, last_date date, is_best boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with p as (select * from public._supplier_price_points() where product_id = p_product),
  agg as (
    select p.variant_id, p.supplier_id,
           (array_agg(p.landed_unit order by p.seq desc))[1] as last_cost,
           round(sum(p.landed_unit * p.qty) filter (where p.invoice_date >= current_date - 180)
                 / nullif(sum(p.qty) filter (where p.invoice_date >= current_date - 180), 0), 2) as avg180,
           max(p.invoice_date) as last_date
      from p group by 1, 2
  )
  select a.variant_id, v.sku, v.size, v.color, a.supplier_id, s.name, a.last_cost, a.avg180, a.last_date,
         a.last_cost = min(a.last_cost) over (partition by a.variant_id)
    from agg a join public.product_variants v on v.id = a.variant_id join public.suppliers s on s.id = a.supplier_id
   order by v.sku, a.last_cost;
end;
$$;

-- ---------------------------------------------------------------------
-- مسودات الشراء من التوصيات: تجميع حسب المورد (المحدد أو المقترح) وموقع الاستلام
--   p_lines: [{variant_id, location_id, qty, supplier_id?}]
-- ---------------------------------------------------------------------
create or replace function public.create_purchase_drafts_by_supplier(p_lines jsonb, p_notes text default null, p_client_ref uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_out jsonb := '[]';
  g record;
  v_ref uuid;
  v_id uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'لا توجد أصناف';
  end if;
  create temp table if not exists _pd (variant_id uuid, location_id uuid, qty integer, supplier_id uuid) on commit drop;
  truncate _pd;
  insert into _pd
  select (e ->> 'variant_id')::uuid, (e ->> 'location_id')::uuid, (e ->> 'qty')::integer, (e ->> 'supplier_id')::uuid
    from jsonb_array_elements(p_lines) e;
  if exists (select 1 from _pd where qty is null or qty <= 0 or location_id is null) then
    raise exception 'كل سطر يحتاج كمية وموقع استلام';
  end if;
  update _pd set supplier_id = s.supplier_id
    from public.suggest_suppliers((select array_agg(distinct variant_id) from _pd where supplier_id is null)) s
   where _pd.supplier_id is null and s.variant_id = _pd.variant_id;
  if exists (select 1 from _pd where supplier_id is null) then
    raise exception 'لا يوجد مورد مقترح لبعض الأصناف (%) — اختر المورد يدوياً',
      (select string_agg(distinct v.sku, '، ') from _pd join public.product_variants v on v.id = _pd.variant_id where _pd.supplier_id is null);
  end if;

  for g in select supplier_id, location_id, jsonb_agg(jsonb_build_object('variant_id', variant_id, 'qty', qty)) as items
             from _pd group by 1, 2 order by 1, 2 loop
    v_ref := case when p_client_ref is null then null else md5(p_client_ref::text || g.supplier_id::text || g.location_id::text)::uuid end;
    if v_ref is not null then
      perform pg_advisory_xact_lock(hashtextextended('pd:' || v_ref::text, 0));
      select id into v_id from public.purchase_orders where client_ref = v_ref;
    else
      v_id := null;
    end if;
    if v_id is null then
      v_id := public.create_purchase_draft_at(g.supplier_id, g.location_id, g.items, coalesce(p_notes, 'مسودة من مركز القرارات'));
      update public.purchase_orders set client_ref = v_ref where id = v_id;
    end if;
    v_out := v_out || jsonb_build_object('id', v_id, 'po_no', (select po_no from public.purchase_orders where id = v_id),
                                         'supplier_id', g.supplier_id, 'location_id', g.location_id);
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- لوحة المشتريات والمستحقات
-- ---------------------------------------------------------------------
create or replace function public.purchasing_dashboard()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return jsonb_build_object(
    'due_this_week', coalesce((select sum(total - settled_amount) from public.supplier_invoices
                                where status in ('posted', 'partially_paid') and coalesce(due_date, invoice_date) between v_today and v_today + 7), 0),
    'overdue', (select jsonb_build_object('d1_30', coalesce(sum(d1_30), 0), 'd31_60', coalesce(sum(d31_60), 0),
                                          'd61_90', coalesce(sum(d61_90), 0), 'd90_plus', coalesce(sum(d90_plus), 0),
                                          'total', coalesce(sum(d1_30 + d31_60 + d61_90 + d90_plus), 0),
                                          'not_due', coalesce(sum(not_due), 0), 'open', coalesce(sum(total_open), 0))
                  from public.supplier_aging(v_today)),
    'top_creditors', coalesce((select jsonb_agg(x) from (
                        select supplier_id, supplier_name, total_open, d1_30 + d31_60 + d61_90 + d90_plus as overdue, credit_limit
                          from public.supplier_aging(v_today) where total_open > 0 order by total_open desc limit 10) x), '[]'),
    'unapplied_credits', coalesce((select sum(unapplied) from public.supplier_aging(v_today)), 0),
    -- مستلم غير مفوتر (التزام لم تصل فاتورته)
    'received_not_invoiced', (select jsonb_build_object(
                                'value', coalesce(sum((gi.qty - gi.qty_invoiced - gi.qty_returned) * gi.unit_cost), 0),
                                'lines', count(*), 'oldest_days', coalesce(max(v_today - (gr.received_at at time zone 'Asia/Riyadh')::date), 0))
                                from public.goods_receipt_items gi join public.goods_receipts gr on gr.id = gi.receipt_id
                               where not gr.is_historical and gi.qty > gi.qty_invoiced + gi.qty_returned),
    'draft_invoices', (select count(*) from public.supplier_invoices where status = 'draft'),
    'purchases_by_month', coalesce((select jsonb_agg(x order by x.month) from (
                              select to_char(date_trunc('month', invoice_date), 'YYYY-MM') as month, sum(subtotal) as subtotal, sum(vat_amount) as vat
                                from public.supplier_invoices
                               where status in ('posted', 'partially_paid', 'paid') and kind <> 'opening' and invoice_date >= date_trunc('month', v_today) - interval '11 months'
                               group by 1) x), '[]'),
    'purchases_by_supplier', coalesce((select jsonb_agg(x) from (
                                 select i.supplier_id, s.name, sum(i.subtotal) as subtotal from public.supplier_invoices i join public.suppliers s on s.id = i.supplier_id
                                  where i.status in ('posted', 'partially_paid', 'paid') and i.kind <> 'opening' and i.invoice_date >= v_today - 90
                                  group by 1, 2 order by 3 desc limit 10) x), '[]'),
    'input_vat_this_month', coalesce((select sum(vat_amount) from public.supplier_invoices
                                       where status in ('posted', 'partially_paid', 'paid') and invoice_date >= date_trunc('month', v_today)), 0)
                          - coalesce((select sum(vat_amount) from public.supplier_credit_notes
                                       where status = 'posted' and credit_date >= date_trunc('month', v_today)), 0),
    'cost_variance_this_month', coalesce((select sum(variance_delta) from public.cost_adjustments
                                           where posted_at >= date_trunc('month', now() at time zone 'Asia/Riyadh') at time zone 'Asia/Riyadh'), 0),
    'price_alerts', coalesce((select jsonb_agg(x) from (
                        select h.supplier_name, h.sku, h.unit_cost, h.change_pct, h.invoice_date
                          from public.supplier_price_history(null, null, 60) h where h.change_pct >= 10
                         order by h.change_pct desc limit 10) x), '[]'),
    'late_orders', coalesce((select jsonb_agg(x) from (
                       select po.id, po.po_no, s.name as supplier_name, po.expected_at, v_today - po.expected_at as days_late
                         from public.purchase_orders po join public.suppliers s on s.id = po.supplier_id
                        where po.status::text in ('ordered', 'partially_received') and po.expected_at < v_today
                        order by po.expected_at limit 20) x), '[]')
  );
end;
$$;

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
  -- المتبقي فقط من المسودة والمرسل والمستلم جزئياً (بعد 0018)
  open_po as (
    select o.variant_id, sum(o.qty)::integer as qty from public._open_po_qty() o group by o.variant_id
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
-- الصلاحيات
-- ---------------------------------------------------------------------
alter table public.supplier_items enable row level security;
revoke all on public.supplier_items from anon;
grant select, insert, update, delete on public.supplier_items to authenticated;
create policy supplier_items_select on public.supplier_items for select to authenticated using (public.is_manager());
create policy supplier_items_write on public.supplier_items for all to authenticated
  using (public.is_manager()) with check (public.is_manager());
create trigger supplier_items_audit after insert or update or delete on public.supplier_items
  for each row execute function public.audit_trigger();

revoke all on function public._supplier_price_points(), public._supplier_performance() from public, anon, authenticated;
revoke execute on function
  public.supplier_price_history(uuid, uuid, integer), public.supplier_scores(uuid[]), public.suggest_suppliers(uuid[]),
  public.supplier_price_comparison(uuid), public.create_purchase_drafts_by_supplier(jsonb, text, uuid),
  public.purchasing_dashboard()
from public, anon;
grant execute on function
  public.supplier_price_history(uuid, uuid, integer), public.supplier_scores(uuid[]), public.suggest_suppliers(uuid[]),
  public.supplier_price_comparison(uuid), public.create_purchase_drafts_by_supplier(jsonb, text, uuid),
  public.purchasing_dashboard()
to authenticated;
