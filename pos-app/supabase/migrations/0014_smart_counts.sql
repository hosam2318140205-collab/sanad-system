-- =====================================================================
-- Smart Inventory 2.0 — (2) الجرد الذكي حسب الموقع
--   • جلسة جرد لكل موقع، مسح بالباركود/SKU من الجوال أو القارئ
--   • كل مسحة سطر مستقل بمفتاح فريد (client_ref): نفس المسحة لا تُحسب مرتين، وجهازان يعدّان نفس الصنف
--     تُجمع مسحاتهما ولا يلغي أحدهما الآخر
--   • الكمية النظامية وقت العدّ = لقطة البداية + حركات الموقع بعد اللقطة حتى لحظة عدّ الصنف
--     فالبيع أثناء الجرد لا يصنع فرقاً وهمياً، والتسوية = المعدود − النظامي وقت العدّ، تُضاف للرصيد الحالي
--   • الكاشير لا يرى الكمية النظامية (جرد أعمى على مستوى قاعدة البيانات)
--   • لا تسوية قبل اعتماد المدير، ولا تسوية تجعل مخزون الموقع سالباً
-- =====================================================================

alter type public.count_status add value if not exists 'submitted';

alter table public.stock_counts
  add column snapshot_at timestamptz,
  add column submitted_by uuid references public.profiles (id),
  add column submitted_at timestamptz,
  add column cancel_reason text;

create table public.stock_count_scans (
  id bigint generated always as identity primary key,
  count_id uuid not null references public.stock_counts (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id) on delete cascade,
  qty integer not null check (qty <> 0),       -- +1 لكل مسحة، أو تصحيح يدوي (±)
  client_ref uuid unique,
  scanned_by uuid references public.profiles (id) default auth.uid(),
  scanned_at timestamptz not null default clock_timestamp()
);
create index stock_count_scans_count_idx on public.stock_count_scans (count_id, variant_id);

-- كمية الموقع في لحظة ماضية = الرصيد الحالي − حركات الموقع بعد تلك اللحظة
create or replace function public._location_qty_at(p_location uuid, p_variant uuid, p_at timestamptz)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce((select qty from public.location_stock where location_id = p_location and variant_id = p_variant), 0)
       - coalesce((select sum(qty_change) from public.location_movements
                    where location_id = p_location and variant_id = p_variant and created_at > p_at), 0)::integer
$$;

create or replace function public.start_location_count(
  p_location uuid, p_category_id uuid default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if (select kind from public.locations where id = p_location and is_active) not in ('store', 'warehouse') then
    raise exception 'موقع غير صالح';
  end if;
  if exists (select 1 from public.stock_counts where location_id = p_location and status in ('open', 'submitted')) then
    raise exception 'يوجد جرد مفتوح لهذا الموقع — أكمله أو ألغه أولاً';
  end if;

  insert into public.stock_counts (count_no, category_id, notes, location_id, snapshot_at)
  values (
    'CNT-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.count_seq')::text, 4, '0'),
    p_category_id, nullif(trim(p_notes), ''), p_location, clock_timestamp()
  ) returning id into v_id;

  -- اللقطة: رصيد الموقع لحظة البدء لكل صنف نشط (ضمن التصنيف إن وُجد)
  insert into public.stock_count_items (count_id, variant_id, expected_qty)
  select v_id, v.id, coalesce(s.qty, 0)
    from public.product_variants v
    join public.products p on p.id = v.product_id
    left join public.location_stock s on s.variant_id = v.id and s.location_id = p_location
   where v.is_active and p.is_active and (p_category_id is null or p.category_id = p_category_id);
  return v_id;
end;
$$;

-- مسحة: p_code = باركود أو SKU. p_qty افتراضياً 1. صنف غير مدرج يُضاف للجرد (مع لقطته)
create or replace function public.record_count_scan(
  p_count_id uuid, p_code text, p_qty integer default 1, p_client_ref uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.stock_counts;
  v_variant record;
  v_item public.stock_count_items;
  v_code text := trim(coalesce(p_code, ''));
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select * into c from public.stock_counts where id = p_count_id;
  if c.id is null or c.status <> 'open' then
    raise exception 'الجرد غير مفتوح';
  end if;

  select v.id, v.sku, p.name, nullif(concat_ws(' / ', v.size, v.color), '') as label into v_variant
    from public.product_variants v join public.products p on p.id = v.product_id
   where v.barcode = v_code or lower(v.sku) = lower(v_code)
   order by (v.barcode = v_code) desc limit 1;
  if v_variant.id is null then
    raise exception 'لا يوجد صنف بالرمز %', v_code;
  end if;

  -- نفس المسحة أُرسلت سابقاً (ضغط مزدوج/إعادة إرسال): لا تُحسب مرة ثانية
  if p_client_ref is not null and exists (select 1 from public.stock_count_scans where client_ref = p_client_ref) then
    select * into v_item from public.stock_count_items where count_id = p_count_id and variant_id = v_variant.id;
    return jsonb_build_object('variant_id', v_variant.id, 'sku', v_variant.sku, 'name', v_variant.name,
                              'label', v_variant.label, 'counted', v_item.counted_qty, 'duplicate', true);
  end if;
  if coalesce(p_qty, 0) = 0 then
    raise exception 'كمية غير صحيحة';
  end if;

  insert into public.stock_count_items (count_id, variant_id, expected_qty)
  values (p_count_id, v_variant.id,
          case when c.location_id is null then (select stock_qty from public.product_variants where id = v_variant.id)
               else public._location_qty_at(c.location_id, v_variant.id, c.snapshot_at) end)
  on conflict (count_id, variant_id) do nothing;

  -- التحديث يقفل الصف: مسحات متزامنة لنفس الصنف تُجمع بالترتيب
  update public.stock_count_items
     set counted_qty = coalesce(counted_qty, 0) + p_qty, counted_by = auth.uid(), counted_at = clock_timestamp()
   where count_id = p_count_id and variant_id = v_variant.id
  returning * into v_item;
  if v_item.counted_qty < 0 then
    raise exception 'الكمية المعدودة لا تكون سالبة';
  end if;
  insert into public.stock_count_scans (count_id, variant_id, qty, client_ref) values (p_count_id, v_variant.id, p_qty, p_client_ref);

  return jsonb_build_object('variant_id', v_variant.id, 'sku', v_variant.sku, 'name', v_variant.name,
                            'label', v_variant.label, 'counted', v_item.counted_qty, 'duplicate', false);
end;
$$;

-- إدخال الكمية المعدودة مباشرة (تُسجَّل كمسحة تصحيح بالفرق)
create or replace function public.set_count_qty(p_count_id uuid, p_variant uuid, p_qty integer, p_client_ref uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_current integer;
begin
  if p_qty is null or p_qty < 0 then
    raise exception 'كمية غير صحيحة';
  end if;
  select coalesce(counted_qty, 0) into v_current from public.stock_count_items
   where count_id = p_count_id and variant_id = p_variant for update;
  if p_qty = coalesce(v_current, 0) then
    update public.stock_count_items set counted_qty = p_qty, counted_by = auth.uid(), counted_at = clock_timestamp()
     where count_id = p_count_id and variant_id = p_variant and counted_qty is null;
    return jsonb_build_object('counted', p_qty);
  end if;
  return public.record_count_scan(p_count_id, (select sku from public.product_variants where id = p_variant),
                                  p_qty - coalesce(v_current, 0), p_client_ref);
end;
$$;

create or replace function public.submit_count(p_count_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  update public.stock_counts set status = 'submitted', submitted_by = auth.uid(), submitted_at = now()
   where id = p_count_id and status = 'open';
  if not found then
    raise exception 'الجرد غير مفتوح';
  end if;
end;
$$;

create or replace function public.reopen_count(p_count_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  update public.stock_counts set status = 'open' where id = p_count_id and status = 'submitted';
  if not found then
    raise exception 'الجرد ليس بانتظار الاعتماد';
  end if;
end;
$$;

-- مراجعة الفروقات (للمدير): النظامي وقت العدّ، المعدود، الفرق، قيمته
create or replace function public.count_review(p_count_id uuid)
returns table (
  variant_id uuid, sku text, product_name text, variant_label text,
  snapshot_qty integer, moves_after_snapshot integer, expected_qty integer,
  counted_qty integer, variance integer, unit_cost numeric, variance_value numeric,
  counted_at timestamptz, current_qty integer
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  c public.stock_counts;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select * into c from public.stock_counts where id = p_count_id;
  if c.id is null then
    raise exception 'الجرد غير موجود';
  end if;
  return query
  with base as (
    select i.variant_id, v.sku, p.name, nullif(concat_ws(' / ', v.size, v.color), '') as label,
           i.expected_qty as snap, i.counted_qty, i.counted_at, coalesce(vc.cost_price, 0) as cost,
           case when c.location_id is null then v.stock_qty
                else coalesce((select s.qty from public.location_stock s
                                where s.location_id = c.location_id and s.variant_id = i.variant_id), 0) end as cur,
           -- حركات الموقع بعد اللقطة حتى لحظة عدّ الصنف (أو حتى الآن إن لم يُعدّ)، دون تسويات هذا الجرد نفسه
           case when c.location_id is null or c.snapshot_at is null then 0
                else coalesce((select sum(m.qty_change) from public.location_movements m
                                where m.location_id = c.location_id and m.variant_id = i.variant_id
                                  and m.created_at > c.snapshot_at
                                  and m.created_at <= coalesce(i.counted_at, clock_timestamp())
                                  and m.ref_id is distinct from c.id), 0)::integer end as moves
      from public.stock_count_items i
      join public.product_variants v on v.id = i.variant_id
      join public.products p on p.id = v.product_id
      left join public.variant_costs vc on vc.variant_id = i.variant_id
     where i.count_id = p_count_id
  )
  select b.variant_id, b.sku, b.name, b.label, b.snap, b.moves, b.snap + b.moves,
         b.counted_qty, b.counted_qty - (b.snap + b.moves), b.cost,
         round((b.counted_qty - (b.snap + b.moves)) * b.cost, 2), b.counted_at, b.cur
    from base b
   order by b.name, b.label;
end;
$$;

-- الاعتماد: التسوية = المعدود − النظامي وقت العدّ. p_uncounted_as_zero للجرد الكامل (غير المعدود = صفر)
create or replace function public.approve_count(p_count_id uuid, p_uncounted_as_zero boolean default false, p_note text default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  c public.stock_counts;
  r record;
  v_delta integer;
  v_changed integer := 0;
  v_current integer;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select * into c from public.stock_counts where id = p_count_id for update;
  if c.id is null or c.status not in ('open', 'submitted') then
    raise exception 'الجرد غير موجود أو مغلق';
  end if;
  if c.location_id is null then
    raise exception 'جرد قديم بدون موقع — استخدم الاعتماد القديم';
  end if;

  for r in select * from public.count_review(p_count_id) loop
    if r.counted_qty is null then
      continue when not p_uncounted_as_zero;
      v_delta := 0 - r.expected_qty;
    else
      v_delta := r.variance;
    end if;
    continue when v_delta = 0;
    perform 1 from public.location_stock where location_id = c.location_id and variant_id = r.variant_id for update;
    v_current := coalesce((select qty from public.location_stock where location_id = c.location_id and variant_id = r.variant_id), 0);
    if v_current + v_delta < 0 then
      raise exception 'تسوية الصنف % تجعل مخزون الموقع سالباً (الحالي %، الفرق %) — راجع العدّ',
        r.sku, v_current, v_delta;
    end if;
    -- تُنسب للموقع عبر stock_counts.location_id، وتغيّر الإجمالي بنفس المقدار
    perform public._move_stock(r.variant_id, v_delta, 'count', p_count_id,
                               c.count_no || coalesce(' — ' || nullif(trim(p_note), ''), ''), false);
    v_changed := v_changed + 1;
  end loop;

  update public.stock_counts set status = 'applied', applied_at = now(), applied_by = auth.uid()
   where id = p_count_id;
  return v_changed;
end;
$$;

create or replace function public.cancel_count(p_count_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  update public.stock_counts set status = 'cancelled', cancel_reason = trim(p_reason)
   where id = p_count_id and status in ('open', 'submitted');
  if not found then
    raise exception 'الجرد غير مفتوح';
  end if;
end;
$$;

-- الدوال القديمة: تعمل كما هي لمتجر بموقع واحد، وترفض عند تعدد المواقع (تقارن بالإجمالي لا بالموقع)
create or replace function public.guard_legacy_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.location_id is null and public._multi_location() then
    raise exception 'تعدد المواقع: استخدم الجرد حسب الموقع';
  end if;
  return new;
end;
$$;
create trigger stock_counts_guard_legacy before insert on public.stock_counts
  for each row execute function public.guard_legacy_count();

create or replace function public.guard_legacy_apply()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'applied' and old.status <> 'applied' and new.location_id is null and public._multi_location() then
    raise exception 'تعدد المواقع: اعتماد الجرد القديم غير متاح';
  end if;
  return new;
end;
$$;
create trigger stock_counts_guard_legacy_apply before update of status on public.stock_counts
  for each row execute function public.guard_legacy_apply();

-- جرد أعمى: الكمية النظامية لا تُقرأ مباشرة (المدير يراها عبر count_review)، والعدّ عبر الدوال فقط
revoke select, update on public.stock_count_items from authenticated;
grant select (id, count_id, variant_id, counted_qty, counted_by, counted_at) on public.stock_count_items to authenticated;

alter table public.stock_count_scans enable row level security;
revoke all on public.stock_count_scans from anon;
revoke insert, update, delete on public.stock_count_scans from authenticated;
grant select on public.stock_count_scans to authenticated;
create policy count_scans_select on public.stock_count_scans for select to authenticated using (public.is_staff());

revoke all on function public._location_qty_at(uuid, uuid, timestamptz), public.guard_legacy_count(),
  public.guard_legacy_apply() from public, anon, authenticated;
revoke execute on function
  public.start_location_count(uuid, uuid, text),
  public.record_count_scan(uuid, text, integer, uuid),
  public.set_count_qty(uuid, uuid, integer, uuid),
  public.submit_count(uuid), public.reopen_count(uuid),
  public.count_review(uuid),
  public.approve_count(uuid, boolean, text),
  public.cancel_count(uuid, text)
from public, anon;
grant execute on function
  public.start_location_count(uuid, uuid, text),
  public.record_count_scan(uuid, text, integer, uuid),
  public.set_count_qty(uuid, uuid, integer, uuid),
  public.submit_count(uuid), public.reopen_count(uuid),
  public.count_review(uuid),
  public.approve_count(uuid, boolean, text),
  public.cancel_count(uuid, text)
to authenticated;
