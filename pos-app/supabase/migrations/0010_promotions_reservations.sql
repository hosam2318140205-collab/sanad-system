-- =====================================================================
-- Sales & Customers 2.0 — (2) العروض والخصومات + حجز المقاسات/الألوان للعملاء
--   • العروض: نسبة % أو مبلغ لكل قطعة أو «اشترِ X واحصل على Y مجاناً»، على كل الأصناف
--     أو تصنيف أو منتج، بفترة صلاحية، ومع رمز كوبون اختياري. التطبيق يتم في الخادم (0011)
--   • الحجز: لكل صنف (منتج + مقاس + لون) كمية محجوزة لعميل حتى تاريخ انتهاء؛ الكمية المحجوزة
--     لا تُباع لغيره، والمخزون نفسه لا يتحرك إلا عند البيع الفعلي
-- إضافة فقط
-- =====================================================================

create type public.promo_kind as enum ('percent', 'amount', 'bxgy');
create type public.promo_scope as enum ('all', 'category', 'product');
create type public.reservation_status as enum ('active', 'fulfilled', 'cancelled');

create table public.promotions (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  kind public.promo_kind not null,
  value numeric(12,2) not null default 0,         -- percent: النسبة، amount: المبلغ لكل قطعة
  buy_qty integer,                                -- bxgy
  get_qty integer,                                -- bxgy
  scope public.promo_scope not null default 'all',
  category_id uuid references public.categories (id) on delete cascade,
  product_id uuid references public.products (id) on delete cascade,
  min_qty integer not null default 1 check (min_qty >= 1),
  code text,                                      -- كوبون اختياري: العرض لا يُطبق إلا بإدخاله
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean not null default true,
  notes text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint promo_value check (
    (kind = 'percent' and value > 0 and value <= 100)
    or (kind = 'amount' and value > 0)
    or (kind = 'bxgy' and coalesce(buy_qty, 0) >= 1 and coalesce(get_qty, 0) >= 1)),
  constraint promo_scope_target check (
    (scope = 'all') or (scope = 'category' and category_id is not null) or (scope = 'product' and product_id is not null)),
  constraint promo_dates check (starts_at is null or ends_at is null or ends_at > starts_at),
  constraint promo_code_format check (code is null or code ~ '^[A-Z0-9_-]{3,30}$')
);
create unique index promotions_code_idx on public.promotions (code) where code is not null;
create trigger promotions_touch before update on public.promotions
  for each row execute function public.touch_updated_at();

-- الكوبون يُخزَّن بحروف كبيرة
create or replace function public.promotions_normalize()
returns trigger language plpgsql as $$
begin
  new.code := nullif(upper(trim(new.code)), '');
  if new.scope <> 'category' then new.category_id := null; end if;
  if new.scope <> 'product' then new.product_id := null; end if;
  if new.kind <> 'bxgy' then new.buy_qty := null; new.get_qty := null; end if;
  if new.kind = 'bxgy' then new.value := 0; end if;
  return new;
end;
$$;
create trigger promotions_normalize before insert or update on public.promotions
  for each row execute function public.promotions_normalize();

-- ---------------------------------------------------------------------
-- الحجوزات
-- ---------------------------------------------------------------------
create sequence public.reservation_seq start 1;

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  reservation_no text not null unique
    default ('RSV-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.reservation_seq')::text, 5, '0')),
  customer_id uuid not null references public.customers (id) on delete restrict,
  status public.reservation_status not null default 'active',
  expires_at timestamptz not null,
  notes text,
  sale_id uuid references public.sales (id),
  client_ref uuid unique,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid references public.profiles (id),
  cancel_reason text
);
create index reservations_customer_idx on public.reservations (customer_id, created_at desc);
create index reservations_active_idx on public.reservations (expires_at) where status = 'active';

create table public.reservation_items (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id),
  qty integer not null check (qty > 0),
  unique (reservation_id, variant_id)
);
create index reservation_items_variant_idx on public.reservation_items (variant_id);

-- عربون الحجز = سند تحصيل مرتبط بالحجز (يُضاف لرصيد العميل الدائن ويُستخدم عند الاستلام)
alter table public.customer_payments
  add constraint customer_payments_reservation_fk foreign key (reservation_id) references public.reservations (id);

create or replace function public.customer_payment_reservation_check()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.reservation_id is not null and not exists (
    select 1 from public.reservations where id = new.reservation_id and customer_id = new.customer_id
  ) then
    raise exception 'الحجز لا يخص هذا العميل';
  end if;
  return new;
end;
$$;
create trigger customer_payments_reservation_check before insert on public.customer_payments
  for each row execute function public.customer_payment_reservation_check();

-- الكمية المحجوزة فعلياً (حجوزات نشطة لم تنتهِ)، مع استثناء حجز معين (عند استلامه)
create or replace function public._reserved_qty(p_variant_id uuid, p_exclude uuid default null)
returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sum(i.qty), 0)::integer
    from public.reservation_items i
    join public.reservations r on r.id = i.reservation_id
   where i.variant_id = p_variant_id and r.status = 'active' and r.expires_at > now()
     and (p_exclude is null or r.id <> p_exclude)
$$;
revoke all on function public._reserved_qty(uuid, uuid) from public, anon, authenticated;

-- للعرض في نقطة البيع: الكميات المحجوزة لكل صنف
create or replace function public.reserved_quantities()
returns table (variant_id uuid, reserved integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  return query
    select i.variant_id, sum(i.qty)::integer
      from public.reservation_items i
      join public.reservations r on r.id = i.reservation_id
     where r.status = 'active' and r.expires_at > now()
     group by i.variant_id;
end;
$$;

-- p_items: [{"variant_id": uuid, "qty": int}]
create or replace function public.create_reservation(
  p_customer_id uuid,
  p_items jsonb,
  p_days integer default null,
  p_notes text default null,
  p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  s public.store_settings;
  v_existing public.reservations;
  v_id uuid;
  v_line record;
  v_available integer;
  v_days integer;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.store_settings where id = 1;

  if p_client_ref is not null then
    select * into v_existing from public.reservations where client_ref = p_client_ref;
    if v_existing.id is not null then
      if v_existing.created_by is distinct from auth.uid() then
        raise exception 'مرجع العملية مستخدم مسبقاً';
      end if;
      return v_existing.id;
    end if;
  end if;

  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'اختر العميل';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'لم يتم اختيار أصناف للحجز';
  end if;
  v_days := coalesce(p_days, s.reservation_days);
  if v_days < 1 or v_days > 60 then
    raise exception 'مدة الحجز بين 1 و60 يوماً';
  end if;

  insert into public.reservations (customer_id, expires_at, notes, client_ref)
  values (p_customer_id, now() + make_interval(days => v_days), nullif(trim(p_notes), ''), p_client_ref)
  returning id into v_id;

  -- نجمع الصنف المكرر، ونقفل صفوف الأصناف لمنع حجزين متزامنين لنفس القطعة
  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'qty')::integer)::integer as qty
      from jsonb_array_elements(p_items) e group by 1 order by 1
  loop
    if v_line.qty is null or v_line.qty <= 0 then
      raise exception 'كمية غير صحيحة';
    end if;
    perform 1 from public.product_variants v join public.products p on p.id = v.product_id
     where v.id = v_line.variant_id and v.is_active and p.is_active for update of v;
    if not found then
      raise exception 'صنف غير موجود أو موقوف';
    end if;
    select v.stock_qty - public._reserved_qty(v.id) into v_available
      from public.product_variants v where v.id = v_line.variant_id;
    if v_line.qty > v_available then
      raise exception 'المتاح للحجز من الصنف % هو % فقط',
        (select sku from public.product_variants where id = v_line.variant_id), greatest(v_available, 0);
    end if;
    insert into public.reservation_items (reservation_id, variant_id, qty) values (v_id, v_line.variant_id, v_line.qty);
  end loop;

  return v_id;
end;
$$;

-- إلغاء: الكاشير لحجوزاته فقط، والمدير لأي حجز. العربون يبقى رصيداً دائناً للعميل
create or replace function public.cancel_reservation(p_reservation_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v public.reservations;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'سبب الإلغاء مطلوب';
  end if;
  select * into v from public.reservations where id = p_reservation_id for update;
  if v.id is null then
    raise exception 'الحجز غير موجود';
  end if;
  if v.status <> 'active' then
    raise exception 'الحجز ليس نشطاً';
  end if;
  if not public.is_manager() and v.created_by is distinct from auth.uid() then
    raise exception 'الكاشير يلغي حجوزاته فقط';
  end if;
  update public.reservations
     set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = v.id;
end;
$$;

-- تمديد حجز نشط (ويُعاد التحقق من التوفر إن كان قد انتهى)
create or replace function public.extend_reservation(p_reservation_id uuid, p_days integer)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  v public.reservations;
  v_line record;
  v_new timestamptz;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if p_days is null or p_days < 1 or p_days > 60 then
    raise exception 'مدة التمديد بين 1 و60 يوماً';
  end if;
  select * into v from public.reservations where id = p_reservation_id for update;
  if v.id is null or v.status <> 'active' then
    raise exception 'الحجز ليس نشطاً';
  end if;
  if v.expires_at <= now() then
    for v_line in select i.variant_id, i.qty from public.reservation_items i where i.reservation_id = v.id loop
      perform 1 from public.product_variants where id = v_line.variant_id for update;
      if v_line.qty > (select stock_qty from public.product_variants where id = v_line.variant_id)
                      - public._reserved_qty(v_line.variant_id, v.id) then
        raise exception 'انتهى الحجز والكمية لم تعد متاحة';
      end if;
    end loop;
  end if;
  v_new := greatest(v.expires_at, now()) + make_interval(days => p_days);
  update public.reservations set expires_at = v_new where id = v.id;
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.promotions enable row level security;
alter table public.reservations enable row level security;
alter table public.reservation_items enable row level security;

revoke all on public.promotions, public.reservations, public.reservation_items from anon;
revoke usage on sequence public.reservation_seq from anon;
grant select, insert, update, delete on public.promotions to authenticated;
revoke insert, update, delete on public.reservations, public.reservation_items from authenticated;
grant select on public.reservations, public.reservation_items to authenticated;

create policy promotions_select on public.promotions for select to authenticated using (public.is_staff());
create policy promotions_write on public.promotions for all to authenticated
  using (public.is_manager()) with check (public.is_manager());
create policy reservations_select on public.reservations for select to authenticated using (public.is_staff());
create policy reservation_items_select on public.reservation_items for select to authenticated using (public.is_staff());

create trigger promotions_audit after insert or update or delete on public.promotions
  for each row execute function public.audit_trigger();
create trigger reservations_audit after insert or update or delete on public.reservations
  for each row execute function public.audit_trigger();

revoke execute on function
  public.reserved_quantities(),
  public.create_reservation(uuid, jsonb, integer, text, uuid),
  public.cancel_reservation(uuid, text),
  public.extend_reservation(uuid, integer)
from public, anon;
grant execute on function
  public.reserved_quantities(),
  public.create_reservation(uuid, jsonb, integer, text, uuid),
  public.cancel_reservation(uuid, text),
  public.extend_reservation(uuid, integer)
to authenticated;
revoke execute on function public.promotions_normalize(), public.customer_payment_reservation_check() from public, anon;
