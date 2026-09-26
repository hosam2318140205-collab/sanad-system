-- ترقية مشروع قائم: نفّذ هذا الملف مرة واحدة في SQL Editor (مولَّد من supabase/migrations/0015_inventory_intelligence.sql)
-- لا تنفذه على مشروع جديد — المشروع الجديد يستخدم 01_all_migrations.sql الذي يتضمنه.
begin;
-- =====================================================================
-- Smart Inventory 2.0 — (3) التوفر لكل موقع + ذكاء المخزون (قراءة فقط)
--   On Hand      : الموجود فعلياً في الموقع (location_stock)
--   Reserved     : محجوز لعملاء (من حجوزات Sales 2.0 إن وُجدت — تُنسب للموقع الرئيسي)
--   Outgoing     : معتمد للتحويل ولم يُشحن بعد
--   Available    : On Hand − Reserved − Outgoing   (المتاح للبيع أو النقل)
--   In Transit   : مشحون إلى الموقع ولم يُستلم بعد
--   المبيعات تُنسب للموقع عبر وردية الكاشير (الوردية بلا موقع = الرئيسي)
-- =====================================================================

-- الحجوزات (إن كانت حزمة Sales 2.0 مثبتة) — بدون اعتماد عليها في وقت التثبيت
create or replace function public._reserved_map()
returns table (location_id uuid, variant_id uuid, qty integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if to_regclass('public.reservation_items') is null or to_regclass('public.reservations') is null then
    return;
  end if;
  return query execute
    'select $1, i.variant_id, sum(i.qty)::integer
       from public.reservation_items i join public.reservations r on r.id = i.reservation_id
      where r.status::text = ''active'' and r.expires_at > now()
      group by i.variant_id'
    using public._default_location();
end;
$$;

-- المبيعات الصافية لكل موقع وصنف (بعد المرتجعات) في نوافذ 7/30/60/90 يوماً + آخر بيع
create or replace function public._location_sales()
returns table (location_id uuid, variant_id uuid, n7 integer, n30 integer, n60 integer, n90 integer, last_sale_at timestamptz,
               first_sale_at timestamptz)
language sql stable security definer set search_path = public as $$
  with d as (select public._default_location() as def),
  s as (
    select coalesce(sh.location_id, d.def) as loc, si.variant_id, si.qty, sa.created_at
      from public.sale_items si
      join public.sales sa on sa.id = si.sale_id
      left join public.shifts sh on sh.id = sa.shift_id
      cross join d
     where sa.created_at >= now() - interval '90 days'
  ),
  r as (
    select coalesce(rsh.location_id, ssh.location_id, d.def) as loc, ri.variant_id, ri.qty, re.created_at
      from public.return_items ri
      join public.returns re on re.id = ri.return_id
      join public.sales sa on sa.id = re.sale_id
      left join public.shifts rsh on rsh.id = re.shift_id
      left join public.shifts ssh on ssh.id = sa.shift_id
      cross join d
     where re.created_at >= now() - interval '90 days'
  ),
  signed as (
    select loc, variant_id, qty, created_at from s
    union all select loc, variant_id, -qty, created_at from r
  ),
  last_sale as (
    select coalesce(sh.location_id, d.def) as loc, si.variant_id, max(sa.created_at) as at, min(sa.created_at) as first_at
      from public.sale_items si
      join public.sales sa on sa.id = si.sale_id
      left join public.shifts sh on sh.id = sa.shift_id
      cross join d
     group by 1, 2
  ),
  agg as (
    select loc, variant_id,
           greatest(coalesce(sum(qty) filter (where created_at >= now() - interval '7 days'), 0), 0)::integer as n7,
           greatest(coalesce(sum(qty) filter (where created_at >= now() - interval '30 days'), 0), 0)::integer as n30,
           greatest(coalesce(sum(qty) filter (where created_at >= now() - interval '60 days'), 0), 0)::integer as n60,
           greatest(coalesce(sum(qty), 0), 0)::integer as n90
      from signed group by loc, variant_id
  )
  select coalesce(a.loc, l.loc), coalesce(a.variant_id, l.variant_id),
         coalesce(a.n7, 0), coalesce(a.n30, 0), coalesce(a.n60, 0), coalesce(a.n90, 0), l.at, l.first_at
    from agg a full join last_sale l on l.loc = a.loc and l.variant_id = a.variant_id
$$;

-- لكل موقع (متجر/مستودع) وصنف: الكميات الخمس + المبيعات + التكلفة والسعر
create or replace function public.location_availability(p_location uuid default null)
returns table (
  location_id uuid, location_name text, location_kind public.location_kind,
  variant_id uuid, product_id uuid, product_name text, category_id uuid, sku text, barcode text,
  size text, color text, on_hand integer, reserved integer, outgoing integer, available integer, in_transit integer,
  incoming_approved integer, n7 integer, n30 integer, n60 integer, n90 integer, last_sale_at timestamptz,
  unit_cost numeric, unit_price numeric, age_days integer
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with locs as (
    select l.* from public.locations l
     where l.is_active and l.kind in ('store', 'warehouse') and (p_location is null or l.id = p_location)
  ),
  res as (select * from public._reserved_map()),
  outg as (
    select t.from_location as loc, i.variant_id, sum(i.qty_approved - i.qty_shipped)::integer as qty
      from public.transfer_items i join public.transfers t on t.id = i.transfer_id
     where t.status in ('approved', 'in_transit') group by 1, 2
  ),
  incoming as (
    select t.to_location as loc, i.variant_id, sum(i.qty_shipped - i.qty_received - i.qty_lost)::integer as qty
      from public.transfer_items i join public.transfers t on t.id = i.transfer_id
     where t.status in ('in_transit', 'short_received') group by 1, 2
  ),
  -- معتمد للتحويل إلى الموقع ولم يُشحن بعد (حتى لا يُقترح نفس النقل مرتين)
  incoming_appr as (
    select t.to_location as loc, i.variant_id, sum(i.qty_approved - i.qty_shipped)::integer as qty
      from public.transfer_items i join public.transfers t on t.id = i.transfer_id
     where t.status in ('approved', 'in_transit') group by 1, 2
  ),
  sales as (select * from public._location_sales()),
  pairs as (
    select l.id as loc, v.id as variant_id
      from locs l cross join public.product_variants v
      join public.products p on p.id = v.product_id
     where (v.is_active and p.is_active)
        or exists (select 1 from public.location_stock s where s.location_id = l.id and s.variant_id = v.id and s.qty <> 0)
  )
  select l.id, l.name, l.kind, v.id, p.id, p.name, p.category_id, v.sku, v.barcode, v.size, v.color,
         coalesce(s.qty, 0), coalesce(r.qty, 0), coalesce(o.qty, 0),
         coalesce(s.qty, 0) - coalesce(r.qty, 0) - coalesce(o.qty, 0),
         coalesce(inc.qty, 0), coalesce(ia.qty, 0),
         coalesce(sa.n7, 0), coalesce(sa.n30, 0), coalesce(sa.n60, 0), coalesce(sa.n90, 0), sa.last_sale_at,
         coalesce(vc.cost_price, 0), coalesce(v.price, p.base_price),
         -- عمر الصنف في الموقع (لتطبيع متوسط البيع): من إضافة الصنف أو افتتاح الموقع، أيهما أحدث.
         -- الموقع الافتراضي يمثل تاريخ المتجر كله (أُنشئ لحظة الترقية) فلا يُحتسب تاريخ إنشائه،
         -- ولا يكون العمر أقصر من أول بيع مسجل في الموقع
         greatest(ceil(extract(epoch from now() - least(
           greatest(v.created_at, case when l.is_default then v.created_at else l.created_at end),
           coalesce(sa.first_sale_at, 'infinity'::timestamptz))) / 86400), 1)::integer
    from pairs pr
    join locs l on l.id = pr.loc
    join public.product_variants v on v.id = pr.variant_id
    join public.products p on p.id = v.product_id
    left join public.location_stock s on s.location_id = l.id and s.variant_id = v.id
    left join res r on r.location_id = l.id and r.variant_id = v.id
    left join outg o on o.loc = l.id and o.variant_id = v.id
    left join incoming inc on inc.loc = l.id and inc.variant_id = v.id
    left join incoming_appr ia on ia.loc = l.id and ia.variant_id = v.id
    left join sales sa on sa.location_id = l.id and sa.variant_id = v.id
    left join public.variant_costs vc on vc.variant_id = v.id;
end;
$$;

-- ---------------------------------------------------------------------
-- نقطة البيع: المتاح في فرع الكاشير (بدون تكلفة) — يُستخدم فقط عند تعدد المواقع
-- ---------------------------------------------------------------------
create or replace function public.pos_location_context()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_loc uuid;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if not public._multi_location() then
    return jsonb_build_object('multi', false);
  end if;
  v_loc := public._my_location();
  return jsonb_build_object(
    'multi', true,
    'location_id', v_loc,
    'location_name', (select name from public.locations where id = v_loc),
    'stock', coalesce((select jsonb_object_agg(s.variant_id, s.qty) from public.location_stock s
                        where s.location_id = v_loc and s.qty <> 0), '{}'::jsonb)
  );
end;
$$;

-- أين يتوفر الصنف؟ (لرسالة «غير متوفر في هذا الفرع — متوفر X في فرع Y»)
create or replace function public.variant_locations(p_variant uuid)
returns table (location_id uuid, location_name text, kind public.location_kind, on_hand integer, available integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  return query
    select l.id, l.name, l.kind, s.qty,
           s.qty - public._outgoing_pending(l.id, p_variant)
             - coalesce((select r.qty from public._reserved_map() r where r.location_id = l.id and r.variant_id = p_variant), 0)
      from public.location_stock s join public.locations l on l.id = s.location_id
     where s.variant_id = p_variant and l.is_active and l.kind in ('store', 'warehouse') and s.qty > 0
     order by s.qty desc;
end;
$$;

-- ---------------------------------------------------------------------
-- المقاسات والألوان الناقصة داخل كل موديل
--   out_of_stock : مقاس/لون موجود في الموديل لكنه نفد في الفرع بينما الموديل يُباع فيه
--   not_created  : المقاس واللون موجودان في الموديل لكن هذا التركيب غير مُنشأ أصلاً
--   الأولوية = الطلب المتوقع (مبيعات 90 يوماً للصنف، أو متوسط أصناف الموديل إن لم يوجد)
-- ---------------------------------------------------------------------
create or replace function public.size_color_gaps(p_location uuid default null)
returns table (
  location_id uuid, location_name text, product_id uuid, product_name text, size text, color text,
  variant_id uuid, gap_kind text, variant_sold_90 integer, model_sold_90 integer, model_sizes_in_stock integer,
  available_elsewhere integer, priority numeric, reason text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with av as (select * from public.location_availability(p_location) a where a.location_kind = 'store'),
  model as (
    select a.location_id, a.product_id, sum(a.n90)::integer as sold90,
           count(*) filter (where a.available > 0)::integer as in_stock,
           count(*)::integer as variants
      from av a group by 1, 2
  ),
  elsewhere as (
    select s.variant_id, s.location_id, (
             select coalesce(sum(o.qty), 0) from public.location_stock o join public.locations l on l.id = o.location_id
              where o.variant_id = s.variant_id and o.location_id <> s.location_id and l.is_active
                and l.kind in ('store', 'warehouse') and o.qty > 0)::integer as qty
      from av s
  ),
  oos as (
    select a.location_id, a.location_name, a.product_id, a.product_name, a.size, a.color, a.variant_id,
           'out_of_stock'::text as kind, a.n90 as vsold, m.sold90, m.in_stock, e.qty as other,
           (greatest(a.n90, round(m.sold90::numeric / greatest(m.variants, 1), 2)))::numeric as prio
      from av a
      join model m on m.location_id = a.location_id and m.product_id = a.product_id
      join elsewhere e on e.variant_id = a.variant_id and e.location_id = a.location_id
     where a.available <= 0 and m.sold90 > 0 and m.variants >= 2
  ),
  dims as (
    select distinct a.location_id, a.location_name, a.product_id, a.product_name, a.size, a.color
      from av a where a.size is not null and a.color is not null
  ),
  missing as (
    select s.location_id, s.location_name, s.product_id, s.product_name, s.size, c.color,
           null::uuid as variant_id, 'not_created'::text as kind, 0 as vsold, m.sold90, m.in_stock, 0 as other,
           round(m.sold90::numeric / greatest(m.variants, 1), 2) as prio
      from (select distinct location_id, location_name, product_id, product_name, size from dims) s
      join (select distinct location_id, product_id, color from dims) c
        on c.location_id = s.location_id and c.product_id = s.product_id
      join model m on m.location_id = s.location_id and m.product_id = s.product_id
     where m.sold90 > 0
       and not exists (select 1 from public.product_variants v
                        where v.product_id = s.product_id and v.size = s.size and v.color = c.color)
  ),
  allg as (select * from oos union all select * from missing)
  select g.location_id, g.location_name, g.product_id, g.product_name, g.size, g.color, g.variant_id, g.kind,
         g.vsold, g.sold90, g.in_stock, g.other, g.prio,
         case g.kind
           when 'out_of_stock' then format(
             'الموديل باع %s قطعة خلال 90 يوماً في %s، وهذا المقاس/اللون نفد (باع هو %s). متوفر %s في مواقع أخرى%s',
             g.sold90, g.location_name, g.vsold, g.other,
             case when g.other > 0 then ' ← انقل قبل أن تشتري' else ' ← يحتاج شراء' end)
           else format(
             'المقاس %s واللون %s موجودان في الموديل الذي باع %s قطعة خلال 90 يوماً، لكن هذا التركيب غير مُنشأ',
             g.size, g.color, g.sold90)
         end
    from allg g
   order by g.prio desc, g.product_name, g.size, g.color;
end;
$$;

-- ---------------------------------------------------------------------
-- المخزون الشاذ — كل تنبيه بسببه وأرقامه
-- ---------------------------------------------------------------------
create or replace function public.inventory_anomalies()
returns table (
  kind text, severity text, location_id uuid, location_name text, variant_id uuid, sku text,
  product_name text, variant_label text, qty integer, value numeric, reason text, ref_id uuid
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with vv as (
    select v.id, v.sku, v.barcode, v.stock_qty, v.is_active, p.name as pname,
           nullif(concat_ws(' / ', v.size, v.color), '') as label,
           coalesce(vc.cost_price, 0) as cost, coalesce(v.price, p.base_price) as price
      from public.product_variants v join public.products p on p.id = v.product_id
      left join public.variant_costs vc on vc.variant_id = v.id
  )
  -- مخزون سالب في موقع
  select 'negative_stock'::text, 'high'::text, s.location_id, l.name, vv.id, vv.sku, vv.pname, vv.label, s.qty,
         round(s.qty * vv.cost, 2),
         format('رصيد %s في %s سالب (%s): بيع أو تسوية أكثر من الموجود — راجع آخر الحركات أو اعمل جرداً', vv.sku, l.name, s.qty),
         null::uuid
    from public.location_stock s join public.locations l on l.id = s.location_id join vv on vv.id = s.variant_id
   where s.qty < 0
  union all
  -- كسر القيد (يجب ألا يحدث)
  select 'invariant', 'high', null, null, vv.id, vv.sku, vv.pname, vv.label, vv.stock_qty, null,
         format('إجمالي الصنف %s ومجموع مواقعه %s غير متطابقين', vv.stock_qty,
                (select coalesce(sum(q.qty), 0) from public.location_stock q where q.variant_id = vv.id)),
         null
    from vv where vv.stock_qty <> (select coalesce(sum(q.qty), 0) from public.location_stock q where q.variant_id = vv.id)
  union all
  -- فروقات تحويل معلقة
  select 'transfer_discrepancy', 'high', t.to_location, l.name, vv.id, vv.sku, vv.pname, vv.label,
         i.qty_shipped - i.qty_received - i.qty_lost,
         round((i.qty_shipped - i.qty_received - i.qty_lost) * vv.cost, 2),
         format('التحويل %s: شُحن %s واستُلم %s — %s قطعة معلقة في الطريق بانتظار اعتماد الفقد أو وصولها',
                t.transfer_no, i.qty_shipped, i.qty_received + i.qty_lost, i.qty_shipped - i.qty_received - i.qty_lost),
         t.id
    from public.transfer_items i join public.transfers t on t.id = i.transfer_id
    join public.locations l on l.id = t.to_location join vv on vv.id = i.variant_id
   where t.status = 'short_received' and i.qty_shipped - i.qty_received - i.qty_lost > 0
  union all
  -- تحويل في الطريق منذ أكثر من 7 أيام
  select 'stale_transit', 'medium', t.to_location, l.name, null, null, null, null,
         (select sum(i.qty_shipped - i.qty_received - i.qty_lost) from public.transfer_items i where i.transfer_id = t.id)::integer,
         null,
         format('التحويل %s في الطريق منذ %s يوماً دون استلام كامل',
                t.transfer_no,
                ((now() at time zone 'Asia/Riyadh')::date
                 - ((select min(e.created_at) from public.transfer_events e where e.transfer_id = t.id and e.event = 'ship')
                    at time zone 'Asia/Riyadh')::date)),
         t.id
    from public.transfers t join public.locations l on l.id = t.to_location
   where t.status = 'in_transit'
     and (select min(e.created_at) from public.transfer_events e where e.transfer_id = t.id and e.event = 'ship') < now() - interval '7 days'
  union all
  -- فروقات جرد كبيرة (آخر 90 يوماً)
  select 'count_variance', 'medium', m.location_id, l.name, vv.id, vv.sku, vv.pname, vv.label, m.qty_change,
         round(m.qty_change * vv.cost, 2),
         format('جرد %s عدّل الرصيد بمقدار %s قطعة (قيمتها %s ر.س بالتكلفة)', coalesce(m.note, ''), m.qty_change,
                round(abs(m.qty_change) * vv.cost, 2)),
         m.ref_id
    from public.location_movements m join public.locations l on l.id = m.location_id join vv on vv.id = m.variant_id
   where m.type = 'count' and m.created_at >= now() - interval '90 days'
     and (abs(m.qty_change) >= 3 or abs(m.qty_change) * vv.cost >= 200)
  union all
  -- تسويات يدوية كبيرة (آخر 30 يوماً)
  select 'large_adjustment', 'medium', m.location_id, l.name, vv.id, vv.sku, vv.pname, vv.label, m.qty_change,
         round(m.qty_change * vv.cost, 2),
         format('تسوية يدوية بمقدار %s قطعة: %s', m.qty_change, coalesce(m.note, 'بدون سبب')),
         null
    from public.location_movements m join public.locations l on l.id = m.location_id join vv on vv.id = m.variant_id
   where m.type = 'adjustment' and m.created_at >= now() - interval '30 days' and abs(m.qty_change) >= 5
  union all
  -- حركة بيع غير طبيعية: مبيعات 7 أيام أكثر من 3 أضعاف المعتاد (ومن 5 قطع فأكثر)
  select 'sales_spike', 'low', a.location_id, l.name, vv.id, vv.sku, vv.pname, vv.label, a.n7, null,
         format('باع %s خلال 7 أيام مقابل متوسط %s أسبوعياً في آخر 90 يوماً — تأكد من صحة البيع أو ارفع الطلب',
                a.n7, round(a.n90 / 90.0 * 7, 1)),
         null
    from public._location_sales() a join public.locations l on l.id = a.location_id join vv on vv.id = a.variant_id
   where a.n7 >= 5 and a.n7 > 3 * (a.n90 / 90.0 * 7)
  union all
  -- مخزون بلا تكلفة
  select 'missing_cost', 'medium', null, null, vv.id, vv.sku, vv.pname, vv.label, vv.stock_qty,
         round(vv.stock_qty * vv.price, 2),
         format('%s قطعة بلا تكلفة مسجلة (قيمتها بالبيع %s ر.س) — الأرباح وقيمة المخزون غير دقيقة',
                vv.stock_qty, round(vv.stock_qty * vv.price, 2)),
         null
    from vv where vv.stock_qty > 0 and vv.cost = 0
  union all
  -- مخزون بلا باركود
  select 'missing_barcode', 'low', null, null, vv.id, vv.sku, vv.pname, vv.label, vv.stock_qty, null,
         format('%s قطعة بلا باركود — المسح في البيع والجرد غير ممكن، ولّد باركوداً من صفحة المنتج', vv.stock_qty),
         null
    from vv where vv.stock_qty > 0 and vv.is_active and vv.barcode is null;
end;
$$;

-- ---------------------------------------------------------------------
-- خطة تصريف الراكد (اقتراح فقط — لا خصومات تلقائية)
--   الأيام بلا بيع في الموقع (أو منذ وصول الصنف للموقع إن لم يُبع فيه)
--   نقل: موقع آخر باع منه في آخر 30 يوماً | عرض: 90–179 يوماً | تخفيض: 180+ | لا إجراء: 30–89 (متابعة)
-- ---------------------------------------------------------------------
create or replace function public.dead_stock_plan(p_location uuid default null)
returns table (
  location_id uuid, location_name text, variant_id uuid, sku text, product_name text, variant_label text,
  on_hand integer, idle_days integer, bucket integer, last_sale_at timestamptz,
  best_location_id uuid, best_location_name text, best_location_sold_30 integer,
  action text, suggested_qty integer, cost_value numeric, retail_value numeric, reason text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with av as (select * from public.location_availability(p_location) a where a.on_hand > 0),
  allsales as (select * from public._location_sales()),
  arrival as (
    select m.location_id, m.variant_id, min(m.created_at) as first_in
      from public.location_movements m where m.qty_change > 0 group by 1, 2
  ),
  x as (
    select a.*,
           greatest(floor(extract(epoch from now() - coalesce(a.last_sale_at, ar.first_in, now())) / 86400), 0)::integer as idle,
           b.location_id as best_loc, bl.name as best_name, coalesce(b.n30, 0) as best30
      from av a
      left join arrival ar on ar.location_id = a.location_id and ar.variant_id = a.variant_id
      left join lateral (
        select s.location_id, s.n30 from allsales s join public.locations l2 on l2.id = s.location_id
         where s.variant_id = a.variant_id and s.location_id <> a.location_id and l2.is_active and l2.kind = 'store'
           and s.n30 >= 2
         order by s.n30 desc limit 1) b on true
      left join public.locations bl on bl.id = b.location_id
  )
  select x.location_id, x.location_name, x.variant_id, x.sku, x.product_name,
         nullif(concat_ws(' / ', x.size, x.color), ''), x.on_hand, x.idle,
         case when x.idle >= 180 then 180 when x.idle >= 90 then 90 when x.idle >= 60 then 60 else 30 end,
         x.last_sale_at, x.best_loc, x.best_name, x.best30,
         case when x.best_loc is not null then 'transfer'
              when x.idle >= 180 then 'markdown'
              when x.idle >= 90 then 'promo'
              else 'none' end,
         case when x.best_loc is not null then least(x.available, x.best30) else x.on_hand end,
         round(x.on_hand * x.unit_cost, 2), round(x.on_hand * x.unit_price, 2),
         case when x.best_loc is not null then format(
                'لم يُبع في %s منذ %s يوماً (لديه %s)، بينما باع %s منه %s قطعة خلال 30 يوماً ← انقل %s',
                x.location_name, x.idle, x.on_hand, x.best_name, x.best30, least(x.available, x.best30))
              when x.idle >= 180 then format('لم يُبع منذ %s يوماً (%s قطعة، %s ر.س بالتكلفة) ولا يُطلب في موقع آخر ← اقترح تخفيضاً',
                x.idle, x.on_hand, round(x.on_hand * x.unit_cost, 2))
              when x.idle >= 90 then format('لم يُبع منذ %s يوماً ولا يُطلب في موقع آخر ← اقترح عرضاً (مثل 2+1) أو إبرازه في الواجهة', x.idle)
              else format('لم يُبع منذ %s يوماً — متابعة فقط', x.idle) end
    from x
   where x.idle >= 30
   order by x.on_hand * x.unit_cost desc;
end;
$$;

revoke all on function public._reserved_map(), public._location_sales() from public, anon, authenticated;
revoke execute on function
  public.location_availability(uuid), public.pos_location_context(), public.variant_locations(uuid),
  public.size_color_gaps(uuid), public.inventory_anomalies(), public.dead_stock_plan(uuid)
from public, anon;
grant execute on function
  public.location_availability(uuid), public.pos_location_context(), public.variant_locations(uuid),
  public.size_color_gaps(uuid), public.inventory_anomalies(), public.dead_stock_plan(uuid)
to authenticated;
commit;
