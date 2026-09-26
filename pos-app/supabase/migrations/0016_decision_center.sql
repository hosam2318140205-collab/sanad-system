-- =====================================================================
-- Smart Inventory 2.0 — (4) مركز قرارات المالك
--   توصيات: اطلب (شراء) / انقل / خفّض / اعرض / راجع — لكل منها الكمية والقيمة بالتكلفة والبيع و«لماذا؟» بالأرقام
--   قاعدة: النقل الداخلي قبل الشراء. احتياج كل فرع يُغطّى أولاً من فائض المواقع الأخرى (الأبطأ بيعاً أولاً)،
--   ولا يُقترح شراء إلا المتبقي بعد النقل
--   الحسابات (مثل مساعد الشراء): متوسط يومي = 20% × 7 أيام + 50% × 30 + 30% × 90 (مطبّع بعمر الصنف في الموقع)
--     نقطة الطلب = المتوسط × (التوريد + الأمان) | المستهدف = المتوسط × (التوريد + الأمان + التغطية)
--     احتياج الفرع = المستهدف − (المتاح + القادم إليه) إذا نزل تحت نقطة الطلب
--     فائض الموقع  = المتاح − مستهدفه (أو كل المتاح إن لم يكن يبيع، ما لم يصله الصنف خلال 30 يوماً)
-- =====================================================================

create or replace function public.decision_center(
  p_lead_days integer default 7, p_cover_days integer default 30, p_safety_days integer default 7
)
returns table (
  action text, priority integer, variant_id uuid, sku text, product_name text, variant_label text,
  from_location uuid, from_name text, to_location uuid, to_name text, qty integer,
  unit_cost numeric, unit_price numeric, cost_value numeric, retail_value numeric, reason text, why jsonb
)
language plpgsql volatile security definer set search_path = public set client_min_messages = warning as $$
#variable_conflict use_column
declare
  r record;
  d record;
  v_remaining integer;
  v_moved integer;
  v_t integer;
  v_parts text[];
  v_elsewhere integer;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_lead_days < 0 or p_cover_days < 1 or p_safety_days < 0 then
    raise exception 'قيم غير صحيحة';
  end if;

  drop table if exists pg_temp._dc;
  drop table if exists pg_temp._dc_out;

  create temp table _dc on commit drop as
  select a.*,
         nullif(concat_ws(' / ', a.size, a.color), '') as label,
         case when a.location_kind = 'store' then round(
             0.2 * a.n7 / least(7, a.age_days)::numeric
           + 0.5 * a.n30 / least(30, a.age_days)::numeric
           + 0.3 * a.n90 / least(90, a.age_days)::numeric, 3) else 0 end as avg_d,
         (select min(m.created_at) from public.location_movements m
           where m.location_id = a.location_id and m.variant_id = a.variant_id and m.qty_change > 0) as first_in
    from public.location_availability(null) a;

  alter table _dc add column target integer, add column rop integer, add column need integer,
                  add column surplus integer, add column rem_surplus integer;
  update _dc set target = ceil(avg_d * (p_lead_days + p_safety_days + p_cover_days))::integer,
                 rop = ceil(avg_d * (p_lead_days + p_safety_days))::integer;
  update _dc set need = case when location_kind = 'store' and avg_d > 0 and available + in_transit + incoming_approved <= rop
                             then greatest(target - (available + in_transit + incoming_approved), 0) else 0 end;
  update _dc set surplus = case
                   when need > 0 then 0
                   when avg_d > 0 then greatest(available - target, 0)
                   -- صنف لا يُباع هنا: فائض كامل، إلا إن وصل حديثاً (أقل من 30 يوماً) — نمنحه فرصة
                   when location_kind = 'store' and first_in > now() - interval '30 days' then 0
                   else greatest(available, 0) end;
  update _dc set rem_surplus = surplus;

  create temp table _dc_out (
    action text, priority integer, variant_id uuid, sku text, product_name text, variant_label text,
    from_location uuid, from_name text, to_location uuid, to_name text, qty integer,
    unit_cost numeric, unit_price numeric, reason text, why jsonb
  ) on commit drop;

  -- النقل ثم الشراء لكل احتياج
  for r in select * from _dc where need > 0 order by avg_d desc, available asc loop
    v_remaining := r.need;
    v_moved := 0;
    v_parts := '{}';
    for d in
      select * from _dc x
       where x.variant_id = r.variant_id and x.location_id <> r.location_id and x.rem_surplus > 0
       order by x.avg_d asc, x.rem_surplus desc
    loop
      exit when v_remaining = 0;
      v_t := least(v_remaining, d.rem_surplus);
      update _dc set rem_surplus = rem_surplus - v_t where location_id = d.location_id and variant_id = d.variant_id;
      v_remaining := v_remaining - v_t;
      v_moved := v_moved + v_t;
      v_parts := v_parts || format('%s من «%s»', v_t, d.location_name);
      insert into _dc_out values (
        'transfer', case when r.available <= 0 then 1 else 2 end,
        r.variant_id, r.sku, r.product_name, r.label,
        d.location_id, d.location_name, r.location_id, r.location_name, v_t, r.unit_cost, r.unit_price,
        format('«%s» لديه %s قطعة (المتاح %s) وباع %s خلال 30 يوماً و%s خلال 60 يوماً، ومستهدفه %s ← فائض %s. '
               '«%s» لديه %s قطعة وباع %s خلال 30 يوماً (%s قطعة/يوم)، نقطة الطلب %s والمستهدف %s ← يحتاج %s. '
               'انقل %s قطعة من «%s» إلى «%s».',
               d.location_name, d.on_hand, d.available, d.n30, d.n60, d.target, d.surplus,
               r.location_name, r.on_hand, r.n30, r.avg_d, r.rop, r.target, r.need,
               v_t, d.location_name, r.location_name),
        jsonb_build_object(
          'from', jsonb_build_object('name', d.location_name, 'on_hand', d.on_hand, 'available', d.available,
                                     'sold_7', d.n7, 'sold_30', d.n30, 'sold_60', d.n60, 'sold_90', d.n90,
                                     'avg_daily', d.avg_d, 'target', d.target, 'surplus', d.surplus),
          'to', jsonb_build_object('name', r.location_name, 'on_hand', r.on_hand, 'available', r.available,
                                   'in_transit', r.in_transit + r.incoming_approved, 'sold_7', r.n7, 'sold_30', r.n30, 'sold_60', r.n60,
                                   'sold_90', r.n90, 'avg_daily', r.avg_d, 'reorder_point', r.rop,
                                   'target', r.target, 'need', r.need),
          'qty', v_t));
    end loop;

    if v_remaining > 0 then
      select coalesce(sum(x.available), 0) into v_elsewhere from _dc x
       where x.variant_id = r.variant_id and x.location_id <> r.location_id and x.available > 0;
      insert into _dc_out values (
        'order', case when r.available <= 0 then 1 else 2 end,
        r.variant_id, r.sku, r.product_name, r.label,
        null, null, r.location_id, r.location_name, v_remaining, r.unit_cost, r.unit_price,
        format('«%s» يبيع %s قطعة/يوم (باع %s خلال 30 يوماً)، والمتاح %s + القادم %s ≤ نقطة الطلب %s ← يحتاج %s. %s اشترِ %s.',
               r.location_name, r.avg_d, r.n30, r.available, r.in_transit + r.incoming_approved, r.rop, r.need,
               case when v_moved > 0 then format('يُغطّى %s بالنقل (%s)، والمتبقي بلا فائض في المواقع الأخرى ←',
                                                  v_moved, array_to_string(v_parts, '، '))
                    when v_elsewhere > 0 then format('متوفر %s في مواقع أخرى لكنها تحتاجه لمبيعاتها ←', v_elsewhere)
                    else 'لا يوجد في أي موقع آخر ←' end,
               v_remaining),
        jsonb_build_object('to', jsonb_build_object('name', r.location_name, 'on_hand', r.on_hand, 'available', r.available,
                                                    'in_transit', r.in_transit + r.incoming_approved, 'sold_30', r.n30, 'sold_90', r.n90,
                                                    'avg_daily', r.avg_d, 'reorder_point', r.rop, 'target', r.target,
                                                    'need', r.need),
                           'covered_by_transfer', v_moved, 'available_elsewhere', v_elsewhere, 'qty', v_remaining));
    end if;
  end loop;

  -- الراكد غير المخصص للنقل: عرض أو تخفيض (اقتراح فقط)
  insert into _dc_out
  select case when p.idle_days >= 180 then 'markdown' else 'promo' end,
         case when p.idle_days >= 180 then 3 else 4 end,
         p.variant_id, p.sku, p.product_name, p.variant_label, p.location_id, p.location_name, null, null,
         p.on_hand, x.unit_cost, x.unit_price,
         case when p.idle_days >= 180
           then format('«%s»: %s قطعة لم تُبع منذ %s يوماً (قيمتها %s ر.س بالتكلفة) ولا يحتاجها موقع آخر ← اقترح تخفيضاً. لا يُطبَّق أي خصم تلقائياً.',
                       p.location_name, p.on_hand, p.idle_days, p.cost_value)
           else format('«%s»: %s قطعة لم تُبع منذ %s يوماً ولا يحتاجها موقع آخر ← اقترح عرضاً (مثل 2+1) أو إبرازها في الواجهة.',
                       p.location_name, p.on_hand, p.idle_days) end,
         jsonb_build_object('on_hand', p.on_hand, 'idle_days', p.idle_days, 'last_sale_at', p.last_sale_at,
                            'cost_value', p.cost_value, 'retail_value', p.retail_value)
    from public.dead_stock_plan(null) p
    join _dc x on x.location_id = p.location_id and x.variant_id = p.variant_id
   where p.idle_days >= 90
     and not exists (select 1 from _dc_out o where o.action = 'transfer'
                      and o.from_location = p.location_id and o.variant_id = p.variant_id);

  -- ما يحتاج مراجعة
  insert into _dc_out
  select 'review', case when a.severity = 'high' then 1 else 3 end,
         a.variant_id, a.sku, a.product_name, a.variant_label, a.location_id, a.location_name, null, null,
         a.qty, null, null, a.reason, jsonb_build_object('kind', a.kind, 'severity', a.severity, 'ref_id', a.ref_id)
    from public.inventory_anomalies() a
   where a.severity in ('high', 'medium');

  return query
    select o.action, o.priority, o.variant_id, o.sku, o.product_name, o.variant_label,
           o.from_location, o.from_name, o.to_location, o.to_name, o.qty, o.unit_cost, o.unit_price,
           round(o.qty * o.unit_cost, 2), round(o.qty * o.unit_price, 2), o.reason, o.why
      from _dc_out o
     order by o.priority, case o.action when 'transfer' then 1 when 'order' then 2 when 'review' then 3
                                        when 'markdown' then 4 else 5 end,
              round(o.qty * coalesce(o.unit_cost, 0), 2) desc nulls last;
end;
$$;

-- تنفيذ توصيات النقل: طلب تحويل لكل (مصدر، وجهة) — ويُعتمد مباشرة ما لم يكن فصل المهام مفعلاً
-- p_lines: [{"from": uuid, "to": uuid, "variant_id": uuid, "qty": int}]
create or replace function public.create_transfers_from_decisions(
  p_lines jsonb, p_notes text default null, p_client_ref uuid default null, p_approve boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g record;
  v_id uuid;
  v_out jsonb := '[]'::jsonb;
  v_seg boolean := (select inventory_segregation from public.store_settings where id = 1);
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'لم يتم اختيار توصيات';
  end if;
  for g in
    select (e ->> 'from')::uuid as f, (e ->> 'to')::uuid as t,
           jsonb_agg(jsonb_build_object('variant_id', e ->> 'variant_id', 'qty', (e ->> 'qty')::integer)) as items
      from jsonb_array_elements(p_lines) e group by 1, 2 order by 1, 2
  loop
    -- مفتاح مشتق لكل مجموعة: إعادة الإرسال لا تُنشئ تحويلاً مكرراً
    v_id := public.request_transfer(g.f, g.t, g.items, coalesce(p_notes, 'من مركز القرارات'),
              case when p_client_ref is null then null
                   else md5(p_client_ref::text || g.f::text || g.t::text)::uuid end);
    if p_approve and not v_seg and (select status from public.transfers where id = v_id) = 'requested' then
      perform public.approve_transfer(v_id, null, 'اعتماد من مركز القرارات');
    end if;
    v_out := v_out || jsonb_build_object('id', v_id, 'transfer_no', (select transfer_no from public.transfers where id = v_id),
                                         'status', (select status from public.transfers where id = v_id));
  end loop;
  return v_out;
end;
$$;

-- تنفيذ توصيات الشراء: مسودة لمورد مع موقع الاستلام (يعيد استخدام create_purchase_draft)
create or replace function public.create_purchase_draft_at(
  p_supplier_id uuid, p_location uuid, p_items jsonb, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  v_id := public.create_purchase_draft(p_supplier_id, p_items, coalesce(p_notes, 'مسودة من مركز القرارات'));
  update public.purchase_orders set location_id = p_location where id = v_id;
  return v_id;
end;
$$;

revoke execute on function
  public.decision_center(integer, integer, integer),
  public.create_transfers_from_decisions(jsonb, text, uuid, boolean),
  public.create_purchase_draft_at(uuid, uuid, jsonb, text)
from public, anon;
grant execute on function
  public.decision_center(integer, integer, integer),
  public.create_transfers_from_decisions(jsonb, text, uuid, boolean),
  public.create_purchase_draft_at(uuid, uuid, jsonb, text)
to authenticated;
