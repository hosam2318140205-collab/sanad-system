-- ترقية مشروع قائم: نفّذ هذا الملف مرة واحدة في SQL Editor (مولَّد من supabase/migrations/0013_locations_transfers.sql)
-- لا تنفذه على مشروع جديد — المشروع الجديد يستخدم 01_all_migrations.sql الذي يتضمنه.
begin;
-- =====================================================================
-- Smart Inventory 2.0 — (1) المواقع ومخزون كل موقع + التحويلات
--   • location_stock / location_movements هما المصدر التفصيلي للحقيقة لكل موقع (فرع/مستودع/في الطريق)
--   • product_variants.stock_qty يبقى الإجمالي، والقيد الإلزامي:
--       مجموع location_stock لكل صنف = product_variants.stock_qty   (يُفحص عند نهاية كل معاملة)
--   • كل حركة في stock_movements (بيع، مرتجع، شراء، جرد، تسوية، افتتاحي) تُنسب لموقعها تلقائياً
--     عبر trigger — دون تعديل complete_sale أو process_return أو receive_purchase
--   • «في الطريق» موقع فعلي: الشحن ينقل من المصدر إليه، والاستلام ينقل منه للوجهة
--   • التحويل ليس بيعاً ولا شراءً: لا يلمس الفواتير ولا التكلفة ولا الضريبة، ولا يغير الإجمالي
--   • متجر بموقع واحد: كل شيء يعمل كما كان تماماً
-- =====================================================================

create type public.location_kind as enum ('store', 'warehouse', 'transit');
create type public.loc_movement_type as enum (
  'opening', 'sale', 'return', 'purchase', 'adjustment', 'count',
  'transfer_out', 'transit_in', 'transit_out', 'transfer_in', 'transit_loss');
create type public.transfer_status as enum (
  'requested', 'approved', 'in_transit', 'short_received', 'completed', 'rejected', 'cancelled');

alter table public.store_settings
  add column inventory_segregation boolean not null default false;   -- فصل المهام في التحويلات والفروقات

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9_-]{2,20}$'),
  name text not null check (length(trim(name)) > 0),
  kind public.location_kind not null default 'store',
  is_default boolean not null default false,
  is_active boolean not null default true,
  address text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint default_is_store check (not is_default or (kind = 'store' and is_active)),
  constraint transit_is_system check (kind <> 'transit' or not is_default)
);
create unique index locations_one_default on public.locations (is_default) where is_default;
create unique index locations_one_transit on public.locations (kind) where kind = 'transit';
create trigger locations_touch before update on public.locations
  for each row execute function public.touch_updated_at();

insert into public.locations (code, name, kind, is_default)
values ('MAIN', coalesce((select store_name from public.store_settings where id = 1), 'المحل الرئيسي'), 'store', true),
       ('TRANSIT', 'بضاعة في الطريق', 'transit', false);

-- موقع عمل كل موظف (يحدده المالك). بدون تعيين = الموقع الرئيسي
create table public.staff_locations (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  location_id uuid not null references public.locations (id),
  updated_at timestamptz not null default now()
);

create table public.location_stock (
  location_id uuid not null references public.locations (id),
  variant_id uuid not null references public.product_variants (id) on delete cascade,
  qty integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (location_id, variant_id)
);
create index location_stock_variant_idx on public.location_stock (variant_id);

create table public.location_movements (
  id bigint generated always as identity primary key,
  location_id uuid not null references public.locations (id),
  variant_id uuid not null references public.product_variants (id) on delete cascade,
  type public.loc_movement_type not null,
  qty_change integer not null check (qty_change <> 0),
  balance_after integer not null,
  stock_movement_id bigint references public.stock_movements (id) on delete cascade,
  transfer_id uuid,
  ref_id uuid,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  -- وقت فعلي (وليس بداية المعاملة) حتى تُرتَّب الحركات بدقة مقابل لقطة الجرد
  created_at timestamptz not null default clock_timestamp()
);
create index location_movements_loc_idx on public.location_movements (location_id, variant_id, created_at);
create index location_movements_variant_idx on public.location_movements (variant_id, created_at);
create index location_movements_transfer_idx on public.location_movements (transfer_id);

alter table public.shifts add column location_id uuid references public.locations (id);
alter table public.purchase_orders add column location_id uuid references public.locations (id);
alter table public.stock_counts add column location_id uuid references public.locations (id);

-- ---------------------------------------------------------------------
-- مساعدات
-- ---------------------------------------------------------------------
create or replace function public._default_location()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.locations where is_default
$$;

create or replace function public._transit_location()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.locations where kind = 'transit'
$$;

-- موقع الموظف الحالي: ورديته المفتوحة، ثم تعيينه، ثم الرئيسي
create or replace function public._my_location()
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(
    (select location_id from public.shifts where cashier_id = auth.uid() and status = 'open'),
    (select location_id from public.staff_locations where profile_id = auth.uid()),
    public._default_location())
$$;

create or replace function public._multi_location()
returns boolean language sql stable security definer set search_path = public as $$
  select count(*) > 1 from public.locations where is_active and kind <> 'transit'
$$;

-- الموقع + الكمية الأكبر خارج موقع معين (لرسالة «متوفر في فرع آخر»)
create or replace function public._best_other_location(p_variant uuid, p_exclude uuid)
returns table (location_name text, qty integer)
language sql stable security definer set search_path = public as $$
  select l.name, s.qty
    from public.location_stock s join public.locations l on l.id = s.location_id
   where s.variant_id = p_variant and s.location_id <> p_exclude and l.kind <> 'transit' and l.is_active and s.qty > 0
   order by s.qty desc, l.name
   limit 1
$$;

-- تحريك مخزون موقع (داخلي): يحدّث الرصيد ويسجّل الحركة. الإجمالي لا يتغير هنا —
-- الحركات التي تغيّر الإجمالي تمر عبر _move_stock ثم trigger النسب أدناه.
create or replace function public._apply_location(
  p_location uuid, p_variant uuid, p_delta integer, p_type public.loc_movement_type,
  p_stock_movement bigint, p_transfer uuid, p_ref uuid, p_note text, p_check_negative boolean
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_balance integer;
begin
  if p_delta = 0 then
    return null;
  end if;
  insert into public.location_stock (location_id, variant_id, qty, updated_at)
  values (p_location, p_variant, p_delta, now())
  on conflict (location_id, variant_id) do update
    set qty = public.location_stock.qty + excluded.qty, updated_at = now()
  returning qty into v_balance;

  if p_check_negative and v_balance < 0 then
    raise exception 'الكمية غير متوفرة في % (المتوفر % فقط)',
      (select name from public.locations where id = p_location), v_balance - p_delta;
  end if;

  insert into public.location_movements
    (location_id, variant_id, type, qty_change, balance_after, stock_movement_id, transfer_id, ref_id, note)
  values (p_location, p_variant, p_type, p_delta, v_balance, p_stock_movement, p_transfer, p_ref, p_note);
  return v_balance;
end;
$$;

-- ---------------------------------------------------------------------
-- نسب كل حركة مخزون إجمالية إلى موقعها
--   بيع/مرتجع ← موقع وردية الكاشير | شراء ← موقع أمر الشراء | جرد ← موقع الجرد
--   غير ذلك (افتتاحي، تسوية) ← الموقع المحدد في الجلسة app.location_id أو الرئيسي
-- البيع من فرع لا يملك كمية محلية كافية مرفوض إن كان المخزون السالب غير مسموح
-- ---------------------------------------------------------------------
create or replace function public.attribute_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_loc uuid := nullif(current_setting('app.location_id', true), '')::uuid;
  v_type public.loc_movement_type :=
    coalesce(nullif(current_setting('app.location_type', true), '')::public.loc_movement_type, new.type::text::public.loc_movement_type);
  v_balance integer;
  v_other record;
  v_allow_negative boolean;
begin
  if coalesce(current_setting('app.skip_location', true), '') = 'on' then
    return new;
  end if;

  if v_loc is null then
    if new.type = 'sale' then
      select sh.location_id into v_loc
        from public.sales s left join public.shifts sh on sh.id = s.shift_id where s.id = new.ref_id;
    elsif new.type = 'return' then
      select coalesce(rsh.location_id, ssh.location_id) into v_loc
        from public.returns r
        left join public.shifts rsh on rsh.id = r.shift_id
        left join public.sales s on s.id = r.sale_id
        left join public.shifts ssh on ssh.id = s.shift_id
       where r.id = new.ref_id;
    elsif new.type = 'purchase' then
      select location_id into v_loc from public.purchase_orders where id = new.ref_id;
    elsif new.type = 'count' then
      select location_id into v_loc from public.stock_counts where id = new.ref_id;
    end if;
  end if;
  v_loc := coalesce(v_loc, public._default_location());

  v_balance := public._apply_location(v_loc, new.variant_id, new.qty_change, v_type, new.id, null, new.ref_id, new.note, false);

  if new.type = 'sale' and v_balance < 0 then
    select allow_negative_stock into v_allow_negative from public.store_settings where id = 1;
    if not v_allow_negative then
      select * into v_other from public._best_other_location(new.variant_id, v_loc);
      raise exception 'غير متوفر في هذا الفرع (%): الصنف % المتوفر % فقط%',
        (select name from public.locations where id = v_loc),
        (select sku from public.product_variants where id = new.variant_id),
        greatest(v_balance - new.qty_change, 0),
        case when v_other.qty is not null
          then format(' — متوفر %s قطع في %s، يمكنك طلب تحويل', v_other.qty, v_other.location_name) else '' end;
    end if;
  end if;
  return new;
end;
$$;

create trigger stock_movements_attribute after insert on public.stock_movements
  for each row execute function public.attribute_stock_movement();

-- ---------------------------------------------------------------------
-- القيد الإلزامي: مجموع مواقع الصنف = إجمالي الصنف (يُفحص عند نهاية المعاملة)
-- أي مسار يعدّل أحدهما دون الآخر يفشل ولا يُحفظ شيء
-- ---------------------------------------------------------------------
create or replace function public._check_location_invariant(p_variant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_total integer;
  v_sum integer;
begin
  select stock_qty into v_total from public.product_variants where id = p_variant;
  if not found then
    return;  -- صنف محذوف (مواقعه تُحذف معه)
  end if;
  select coalesce(sum(qty), 0) into v_sum from public.location_stock where variant_id = p_variant;
  if v_sum <> v_total then
    raise exception 'تعارض مخزون: الصنف % إجماليه % ومجموع مواقعه %',
      (select sku from public.product_variants where id = p_variant), v_total, v_sum
      using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.location_stock_invariant()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._check_location_invariant(coalesce(new.variant_id, old.variant_id));
  return null;
end;
$$;

create or replace function public.variant_stock_invariant()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._check_location_invariant(new.id);
  return null;
end;
$$;

create constraint trigger location_stock_invariant
  after insert or update or delete on public.location_stock
  deferrable initially deferred
  for each row execute function public.location_stock_invariant();

create constraint trigger variant_stock_invariant
  after insert or update of stock_qty on public.product_variants
  deferrable initially deferred
  for each row execute function public.variant_stock_invariant();

-- الأرصدة الحالية كلها في الموقع الرئيسي (إضافة فقط — لا تغيير على أي صف قائم)
insert into public.location_stock (location_id, variant_id, qty)
select public._default_location(), id, stock_qty from public.product_variants where stock_qty <> 0;
-- الرصيد الافتتاحي يُؤرَّخ بتاريخ إضافة الصنف لا بلحظة الترقية: وإلا بدا كل المخزون «وصل اليوم»
-- (راكد = 0 يوم، وحماية الوارد الجديد تمنع اقتراح النقل من الرئيسي 30 يوماً)
insert into public.location_movements (location_id, variant_id, type, qty_change, balance_after, note, created_at)
select public._default_location(), id, 'opening', stock_qty, stock_qty, 'رصيد عند تفعيل المواقع', created_at
  from public.product_variants where stock_qty <> 0;

-- ---------------------------------------------------------------------
-- موقع الوردية وأمر الشراء (عند الإنشاء)
-- ---------------------------------------------------------------------
create or replace function public.shift_set_location()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.location_id is null then
    new.location_id := coalesce(
      (select location_id from public.staff_locations where profile_id = new.cashier_id),
      public._default_location());
  end if;
  if (select kind from public.locations where id = new.location_id) = 'transit' then
    raise exception 'موقع غير صالح';
  end if;
  return new;
end;
$$;
create trigger shifts_set_location before insert on public.shifts
  for each row execute function public.shift_set_location();

create or replace function public.purchase_set_location()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.location_id is null then
    new.location_id := public._default_location();
  end if;
  if (select kind from public.locations where id = new.location_id) = 'transit'
     or not (select is_active from public.locations where id = new.location_id) then
    raise exception 'موقع الاستلام غير صالح';
  end if;
  -- بعد الاستلام لا يُغيَّر موقع أمر الشراء (الحركات نُسبت إليه)
  if tg_op = 'UPDATE' and old.status = 'received' and new.location_id is distinct from old.location_id then
    raise exception 'لا يمكن تغيير موقع أمر شراء مستلم';
  end if;
  return new;
end;
$$;
create trigger purchase_orders_set_location before insert or update of location_id on public.purchase_orders
  for each row execute function public.purchase_set_location();

-- ---------------------------------------------------------------------
-- منع التكرار لعمليات المخزون (مفتاح لكل عملية من الواجهة)
-- ---------------------------------------------------------------------
create table public.inventory_ops (
  client_ref uuid primary key,
  op text not null,
  ref_id uuid,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);

-- يعيد true إن كانت العملية نُفذت سابقاً (فيتوقف المستدعي دون أي أثر)
create or replace function public._op_seen(p_client_ref uuid, p_op text, p_ref uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v public.inventory_ops;
begin
  if p_client_ref is null then
    return false;
  end if;
  -- الحجز بالإدراج: جلسة متزامنة بنفس المرجع تنتظر هنا ثم تعامَل كتكرار (لا خطأ تفرد ولا تنفيذ مزدوج)
  insert into public.inventory_ops (client_ref, op, ref_id) values (p_client_ref, p_op, p_ref)
  on conflict (client_ref) do nothing;
  if found then
    return false;
  end if;
  select * into v from public.inventory_ops where client_ref = p_client_ref;
  if v.op <> p_op or v.created_by is distinct from auth.uid() then
    raise exception 'مرجع العملية مستخدم مسبقاً';
  end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- تسوية مخزون موقع محدد (للمدير) — لا يُسمح بالنزول تحت الصفر
-- ---------------------------------------------------------------------
create or replace function public.adjust_location_stock(
  p_location uuid, p_variant uuid, p_qty_change integer, p_note text, p_client_ref uuid default null
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_balance integer;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(p_qty_change, 0) = 0 or coalesce(trim(p_note), '') = '' then
    raise exception 'أدخل الكمية والسبب';
  end if;
  if (select kind from public.locations where id = p_location and is_active) is distinct from 'store'
     and (select kind from public.locations where id = p_location and is_active) is distinct from 'warehouse' then
    raise exception 'موقع غير صالح';
  end if;
  if public._op_seen(p_client_ref, 'adjust', p_variant) then
    return (select qty from public.location_stock where location_id = p_location and variant_id = p_variant);
  end if;
  perform 1 from public.location_stock where location_id = p_location and variant_id = p_variant for update;
  if coalesce((select qty from public.location_stock where location_id = p_location and variant_id = p_variant), 0)
     + p_qty_change < 0 then
    raise exception 'التسوية تجعل مخزون الموقع سالباً';
  end if;
  perform set_config('app.location_id', p_location::text, true);
  perform public._move_stock(p_variant, p_qty_change, 'adjustment', null, trim(p_note), false);
  perform set_config('app.location_id', '', true);
  return (select qty from public.location_stock where location_id = p_location and variant_id = p_variant);
end;
$$;

-- =====================================================================
-- التحويلات: طلب ← اعتماد ← شحن (جزئي/كلي) ← استلام (جزئي/كلي) ← فروقات معلقة ← اعتماد الفقد
-- =====================================================================
create sequence public.transfer_seq start 1;

create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  transfer_no text not null unique
    default ('TRF-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.transfer_seq')::text, 5, '0')),
  from_location uuid not null references public.locations (id),
  to_location uuid not null references public.locations (id),
  status public.transfer_status not null default 'requested',
  notes text,
  client_ref uuid unique,
  requested_by uuid references public.profiles (id) default auth.uid(),
  requested_at timestamptz not null default now(),
  approved_by uuid references public.profiles (id),
  approved_at timestamptz,
  closed_by uuid references public.profiles (id),
  closed_at timestamptz,
  close_reason text,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint transfer_distinct check (from_location <> to_location)
);
create index transfers_status_idx on public.transfers (status, requested_at desc);
create trigger transfers_touch before update on public.transfers
  for each row execute function public.touch_updated_at();

create table public.transfer_items (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.transfers (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id),
  qty_requested integer not null check (qty_requested > 0),
  qty_approved integer not null default 0 check (qty_approved >= 0),
  qty_shipped integer not null default 0 check (qty_shipped >= 0),
  qty_received integer not null default 0 check (qty_received >= 0),
  qty_lost integer not null default 0 check (qty_lost >= 0),
  discrepancy_by uuid references public.profiles (id),   -- من أنهى الاستلام بنقص (لفصل المهام)
  discrepancy_at timestamptz,
  unique (transfer_id, variant_id),
  constraint shipped_le_approved check (qty_shipped <= qty_approved or qty_approved = 0 and qty_shipped = 0),
  constraint settled_le_shipped check (qty_received + qty_lost <= qty_shipped)
);

-- التسلسل الزمني الكامل: من طلب/اعتمد/شحن/استلم/اعتمد الفقد، ومتى، وبأي كمية
create table public.transfer_events (
  id bigint generated always as identity primary key,
  transfer_id uuid not null references public.transfers (id) on delete cascade,
  event text not null check (event in ('request', 'approve', 'reject', 'cancel', 'ship', 'close_remaining',
                                       'receive', 'finalize', 'loss')),
  variant_id uuid references public.product_variants (id),
  qty integer,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index transfer_events_transfer_idx on public.transfer_events (transfer_id, id);

-- الكمية المعتمدة التي لم تُشحن بعد من موقع (محجوزة للتحويل الصادر)
create or replace function public._outgoing_pending(p_location uuid, p_variant uuid, p_exclude uuid default null)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(i.qty_approved - i.qty_shipped), 0)::integer
    from public.transfer_items i join public.transfers t on t.id = i.transfer_id
   where t.from_location = p_location and i.variant_id = p_variant
     and t.status in ('approved', 'in_transit') and (p_exclude is null or t.id <> p_exclude)
$$;

create or replace function public._can_act_at(p_location uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_manager() or (public.is_staff() and public._my_location() = p_location)
$$;

-- تحديث حالة التحويل من كمياته
create or replace function public._transfer_refresh(p_id uuid, p_finalize boolean)
returns public.transfer_status
language plpgsql security definer set search_path = public as $$
declare
  v_pending_ship integer;
  v_pending_recv integer;
  v_status public.transfer_status;
begin
  select coalesce(sum(qty_approved - qty_shipped), 0), coalesce(sum(qty_shipped - qty_received - qty_lost), 0)
    into v_pending_ship, v_pending_recv
    from public.transfer_items where transfer_id = p_id;

  if v_pending_ship = 0 and v_pending_recv = 0 then
    v_status := 'completed';
  elsif v_pending_ship = 0 and (p_finalize or (select status from public.transfers where id = p_id) = 'short_received') then
    v_status := 'short_received';
    update public.transfer_items
       set discrepancy_by = coalesce(discrepancy_by, auth.uid()), discrepancy_at = coalesce(discrepancy_at, now())
     where transfer_id = p_id and qty_shipped - qty_received - qty_lost > 0;
  else
    v_status := 'in_transit';
  end if;

  update public.transfers
     set status = v_status,
         completed_at = case when v_status = 'completed' then now() end
   where id = p_id;
  return v_status;
end;
$$;

-- p_items: [{"variant_id": uuid, "qty": int}]
create or replace function public.request_transfer(
  p_from uuid, p_to uuid, p_items jsonb, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_existing public.transfers;
  v_id uuid;
  v_line record;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if p_client_ref is not null then
    -- نفس الطلب من جلستين متزامنتين: الثانية تنتظر ثم تجد الطلب الأول
    perform pg_advisory_xact_lock(hashtextextended('transfer:' || p_client_ref::text, 0));
    select * into v_existing from public.transfers where client_ref = p_client_ref;
    if v_existing.id is not null then
      if v_existing.requested_by is distinct from auth.uid() then
        raise exception 'مرجع العملية مستخدم مسبقاً';
      end if;
      return v_existing.id;
    end if;
  end if;
  if p_from = p_to then
    raise exception 'اختر موقعين مختلفين';
  end if;
  if exists (select 1 from public.locations where id in (p_from, p_to) and (kind = 'transit' or not is_active))
     or (select count(*) from public.locations where id in (p_from, p_to)) <> 2 then
    raise exception 'موقع غير صالح';
  end if;
  if not public.is_manager() and public._my_location() not in (p_from, p_to) then
    raise exception 'الكاشير يطلب التحويل من/إلى فرعه فقط';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'لم يتم اختيار أصناف';
  end if;

  insert into public.transfers (from_location, to_location, notes, client_ref)
  values (p_from, p_to, nullif(trim(p_notes), ''), p_client_ref)
  returning id into v_id;

  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'qty')::integer)::integer as qty
      from jsonb_array_elements(p_items) e group by 1
  loop
    if v_line.qty is null or v_line.qty <= 0 then
      raise exception 'كمية غير صحيحة';
    end if;
    if not exists (select 1 from public.product_variants where id = v_line.variant_id) then
      raise exception 'صنف غير موجود';
    end if;
    insert into public.transfer_items (transfer_id, variant_id, qty_requested) values (v_id, v_line.variant_id, v_line.qty);
    insert into public.transfer_events (transfer_id, event, variant_id, qty) values (v_id, 'request', v_line.variant_id, v_line.qty);
  end loop;
  return v_id;
end;
$$;

-- الاعتماد يحجز الكمية من «المتاح» في المصدر. p_items اختياري لتعديل الكميات المعتمدة (0 = استبعاد)
create or replace function public.approve_transfer(p_id uuid, p_items jsonb default null, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  t public.transfers;
  v_item record;
  v_qty integer;
  v_available integer;
  v_seg boolean := (select inventory_segregation from public.store_settings where id = 1);
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select * into t from public.transfers where id = p_id for update;
  if t.id is null or t.status <> 'requested' then
    raise exception 'التحويل ليس بانتظار الاعتماد';
  end if;
  if v_seg and t.requested_by = auth.uid() then
    raise exception 'فصل المهام: لا يمكنك اعتماد طلب أنشأته بنفسك';
  end if;

  for v_item in select * from public.transfer_items where transfer_id = p_id order by variant_id loop
    v_qty := coalesce((select (e ->> 'qty')::integer from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e
                        where (e ->> 'variant_id')::uuid = v_item.variant_id), v_item.qty_requested);
    if v_qty < 0 then
      raise exception 'كمية غير صحيحة';
    end if;
    -- قفل رصيد المصدر لمنع اعتمادين متزامنين يتجاوزان المتاح
    perform 1 from public.location_stock where location_id = t.from_location and variant_id = v_item.variant_id for update;
    v_available := coalesce((select qty from public.location_stock where location_id = t.from_location and variant_id = v_item.variant_id), 0)
                   - public._outgoing_pending(t.from_location, v_item.variant_id, p_id);
    if v_qty > v_available then
      raise exception 'المتاح في المصدر من الصنف % هو % فقط',
        (select sku from public.product_variants where id = v_item.variant_id), greatest(v_available, 0);
    end if;
    update public.transfer_items set qty_approved = v_qty where id = v_item.id;
    insert into public.transfer_events (transfer_id, event, variant_id, qty, note)
    values (p_id, 'approve', v_item.variant_id, v_qty, nullif(trim(p_note), ''));
  end loop;
  if not exists (select 1 from public.transfer_items where transfer_id = p_id and qty_approved > 0) then
    raise exception 'لا توجد كميات معتمدة — استخدم الرفض بدلاً من ذلك';
  end if;
  update public.transfers set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_id;
end;
$$;

-- رفض (للمدير) أو إلغاء (صاحب الطلب قبل الاعتماد، أو المدير قبل أي شحن)
create or replace function public.close_transfer(p_id uuid, p_reason text, p_reject boolean default false)
returns void
language plpgsql security definer set search_path = public as $$
declare
  t public.transfers;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  select * into t from public.transfers where id = p_id for update;
  if t.id is null then
    raise exception 'التحويل غير موجود';
  end if;
  if p_reject then
    if not public.is_manager() or t.status <> 'requested' then
      raise exception 'لا يمكن رفض هذا التحويل';
    end if;
  else
    if exists (select 1 from public.transfer_items where transfer_id = p_id and qty_shipped > 0) then
      raise exception 'تم شحن جزء من التحويل — لا يمكن إلغاؤه (استلم أو اعتمد الفرق)';
    end if;
    if not (t.status = 'requested' and (t.requested_by = auth.uid() or public.is_manager())
            or t.status = 'approved' and public.is_manager()) then
      raise exception 'لا يمكن إلغاء هذا التحويل';
    end if;
  end if;
  update public.transfers
     set status = case when p_reject then 'rejected'::public.transfer_status else 'cancelled'::public.transfer_status end,
         closed_by = auth.uid(), closed_at = now(), close_reason = trim(p_reason)
   where id = p_id;
  insert into public.transfer_events (transfer_id, event, note)
  values (p_id, case when p_reject then 'reject' else 'cancel' end, trim(p_reason));
end;
$$;

-- الشحن: من المصدر إلى «في الطريق». p_items null = كل المتبقي المعتمد.
-- p_close_remaining: إنهاء الشحن (ما لم يُشحن يُلغى من المعتمد)
create or replace function public.ship_transfer(
  p_id uuid, p_items jsonb default null, p_close_remaining boolean default false, p_client_ref uuid default null
) returns public.transfer_status
language plpgsql security definer set search_path = public as $$
declare
  t public.transfers;
  v_item record;
  v_qty integer;
  v_transit uuid := public._transit_location();
  v_any boolean := false;
begin
  select * into t from public.transfers where id = p_id for update;
  if t.id is null then
    raise exception 'التحويل غير موجود';
  end if;
  if not public._can_act_at(t.from_location) then
    raise exception 'الشحن من موظفي موقع المصدر أو المدير';
  end if;
  if public._op_seen(p_client_ref, 'ship', p_id) then
    return t.status;
  end if;
  if t.status not in ('approved', 'in_transit') then
    raise exception 'لا يمكن الشحن في حالة التحويل الحالية';
  end if;

  for v_item in select * from public.transfer_items where transfer_id = p_id order by variant_id loop
    v_qty := case when p_items is null then v_item.qty_approved - v_item.qty_shipped
                  else coalesce((select (e ->> 'qty')::integer from jsonb_array_elements(p_items) e
                                  where (e ->> 'variant_id')::uuid = v_item.variant_id), 0) end;
    if v_qty < 0 or v_qty > v_item.qty_approved - v_item.qty_shipped then
      raise exception 'كمية الشحن للصنف % تتجاوز المعتمد المتبقي (%)',
        (select sku from public.product_variants where id = v_item.variant_id), v_item.qty_approved - v_item.qty_shipped;
    end if;
    if v_qty > 0 then
      -- لا مخزون سالب في المصدر (القفل داخل _apply_location يمنع شحنين متزامنين يتجاوزان الرصيد)
      perform public._apply_location(t.from_location, v_item.variant_id, -v_qty, 'transfer_out', null, p_id, null, t.transfer_no, true);
      perform public._apply_location(v_transit, v_item.variant_id, v_qty, 'transit_in', null, p_id, null, t.transfer_no, false);
      update public.transfer_items set qty_shipped = qty_shipped + v_qty where id = v_item.id;
      insert into public.transfer_events (transfer_id, event, variant_id, qty) values (p_id, 'ship', v_item.variant_id, v_qty);
      v_any := true;
    end if;
  end loop;

  if p_close_remaining then
    update public.transfer_items set qty_approved = qty_shipped where transfer_id = p_id and qty_approved > qty_shipped;
    insert into public.transfer_events (transfer_id, event, note) values (p_id, 'close_remaining', 'إنهاء الشحن');
  elsif not v_any then
    raise exception 'لا توجد كميات للشحن';
  end if;
  return public._transfer_refresh(p_id, false);
end;
$$;

-- الاستلام: من «في الطريق» إلى الوجهة. p_items null = كل المشحون غير المستلم.
-- p_finalize: إنهاء الاستلام — أي نقص يبقى فرقاً معلقاً في «في الطريق» (short_received) حتى يُعتمد كفقد أو يصل لاحقاً
create or replace function public.receive_transfer(
  p_id uuid, p_items jsonb default null, p_finalize boolean default true, p_client_ref uuid default null
) returns public.transfer_status
language plpgsql security definer set search_path = public as $$
declare
  t public.transfers;
  v_item record;
  v_qty integer;
  v_transit uuid := public._transit_location();
  v_any boolean := false;
begin
  select * into t from public.transfers where id = p_id for update;
  if t.id is null then
    raise exception 'التحويل غير موجود';
  end if;
  if not public._can_act_at(t.to_location) then
    raise exception 'الاستلام من موظفي موقع الوجهة أو المدير';
  end if;
  if public._op_seen(p_client_ref, 'receive', p_id) then
    return t.status;
  end if;
  if t.status not in ('in_transit', 'short_received') then
    raise exception 'لا توجد كمية بانتظار الاستلام في هذا التحويل';
  end if;

  for v_item in select * from public.transfer_items where transfer_id = p_id order by variant_id loop
    v_qty := case when p_items is null then v_item.qty_shipped - v_item.qty_received - v_item.qty_lost
                  else coalesce((select (e ->> 'qty')::integer from jsonb_array_elements(p_items) e
                                  where (e ->> 'variant_id')::uuid = v_item.variant_id), 0) end;
    if v_qty < 0 or v_qty > v_item.qty_shipped - v_item.qty_received - v_item.qty_lost then
      raise exception 'الكمية المستلمة للصنف % أكبر من المشحون المتبقي (%)',
        (select sku from public.product_variants where id = v_item.variant_id),
        v_item.qty_shipped - v_item.qty_received - v_item.qty_lost;
    end if;
    if v_qty > 0 then
      perform public._apply_location(v_transit, v_item.variant_id, -v_qty, 'transit_out', null, p_id, null, t.transfer_no, true);
      perform public._apply_location(t.to_location, v_item.variant_id, v_qty, 'transfer_in', null, p_id, null, t.transfer_no, false);
      update public.transfer_items set qty_received = qty_received + v_qty where id = v_item.id;
      insert into public.transfer_events (transfer_id, event, variant_id, qty) values (p_id, 'receive', v_item.variant_id, v_qty);
      v_any := true;
    end if;
  end loop;
  if not v_any and not p_finalize then
    raise exception 'لا توجد كميات للاستلام';
  end if;
  if p_finalize then
    insert into public.transfer_events (transfer_id, event) values (p_id, 'finalize');
  end if;
  return public._transfer_refresh(p_id, p_finalize);
end;
$$;

-- اعتماد فرق التحويل كفقد نهائي (المالك/المدير، سبب إلزامي، مع فصل المهام إن كان مفعلاً)
create or replace function public.resolve_transfer_loss(
  p_id uuid, p_variant uuid, p_qty integer, p_reason text, p_client_ref uuid default null
) returns public.transfer_status
language plpgsql security definer set search_path = public as $$
declare
  t public.transfers;
  v_item public.transfer_items;
  v_seg boolean := (select inventory_segregation from public.store_settings where id = 1);
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'سبب اعتماد الفقد مطلوب';
  end if;
  select * into t from public.transfers where id = p_id for update;
  if t.id is null or t.status <> 'short_received' then
    raise exception 'لا يوجد فرق معلق في هذا التحويل';
  end if;
  if public._op_seen(p_client_ref, 'loss', p_id) then
    return t.status;
  end if;
  select * into v_item from public.transfer_items where transfer_id = p_id and variant_id = p_variant for update;
  if v_item.id is null or p_qty is null or p_qty <= 0
     or p_qty > v_item.qty_shipped - v_item.qty_received - v_item.qty_lost then
    raise exception 'كمية الفقد أكبر من الفرق المعلق';
  end if;
  if v_seg and v_item.discrepancy_by = auth.uid() then
    raise exception 'فصل المهام: لا يمكنك اعتماد فرق سجّلته بنفسك';
  end if;

  -- الفقد يخفض الإجمالي عبر _move_stock، ونسبته إلى موقع «في الطريق»
  perform set_config('app.location_id', public._transit_location()::text, true);
  perform set_config('app.location_type', 'transit_loss', true);
  perform public._move_stock(p_variant, -p_qty, 'adjustment', p_id, 'فقد تحويل ' || t.transfer_no || ': ' || trim(p_reason), false);
  perform set_config('app.location_id', '', true);
  perform set_config('app.location_type', '', true);

  update public.transfer_items set qty_lost = qty_lost + p_qty where id = v_item.id;
  insert into public.transfer_events (transfer_id, event, variant_id, qty, note)
  values (p_id, 'loss', p_variant, p_qty, trim(p_reason));
  return public._transfer_refresh(p_id, false);
end;
$$;

-- ---------------------------------------------------------------------
-- إدارة المواقع (المالك)
-- ---------------------------------------------------------------------
create or replace function public.set_staff_location(p_profile uuid, p_location uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner') then
    raise exception 'غير مصرح';
  end if;
  if p_location is null then
    delete from public.staff_locations where profile_id = p_profile;
    return;
  end if;
  if (select kind from public.locations where id = p_location and is_active) is null
     or (select kind from public.locations where id = p_location) = 'transit' then
    raise exception 'موقع غير صالح';
  end if;
  insert into public.staff_locations (profile_id, location_id) values (p_profile, p_location)
  on conflict (profile_id) do update set location_id = excluded.location_id, updated_at = now();
end;
$$;

-- لا يُعطَّل موقع فيه مخزون أو تحويلات مفتوحة، ولا يُعدَّل نوع «في الطريق»
create or replace function public.locations_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if old.kind = 'transit' and (new.kind <> 'transit' or not new.is_active) then
      raise exception 'موقع «في الطريق» موقع نظام';
    end if;
    if new.kind = 'transit' and old.kind <> 'transit' then
      raise exception 'لا يمكن تحويل موقع إلى «في الطريق»';
    end if;
    if old.is_active and not new.is_active then
      if exists (select 1 from public.location_stock where location_id = old.id and qty <> 0) then
        raise exception 'لا يمكن تعطيل موقع فيه مخزون — انقله أولاً';
      end if;
      if exists (select 1 from public.transfers where old.id in (from_location, to_location)
                  and status in ('requested', 'approved', 'in_transit', 'short_received')) then
        raise exception 'لا يمكن تعطيل موقع له تحويلات مفتوحة';
      end if;
    end if;
  elsif tg_op = 'INSERT' and new.kind = 'transit' then
    raise exception 'موقع «في الطريق» موجود مسبقاً';
  end if;
  return new;
end;
$$;
create trigger locations_guard before insert or update on public.locations
  for each row execute function public.locations_guard();

-- ---------------------------------------------------------------------
-- RLS والصلاحيات
-- ---------------------------------------------------------------------
alter table public.locations enable row level security;
alter table public.staff_locations enable row level security;
alter table public.location_stock enable row level security;
alter table public.location_movements enable row level security;
alter table public.transfers enable row level security;
alter table public.transfer_items enable row level security;
alter table public.transfer_events enable row level security;
alter table public.inventory_ops enable row level security;

revoke all on public.locations, public.staff_locations, public.location_stock, public.location_movements,
  public.transfers, public.transfer_items, public.transfer_events, public.inventory_ops from anon;
revoke usage on sequence public.transfer_seq from anon;
revoke insert, update, delete on public.staff_locations, public.location_stock, public.location_movements,
  public.transfers, public.transfer_items, public.transfer_events, public.inventory_ops from authenticated;
revoke all on public.inventory_ops from authenticated;
grant select on public.locations, public.staff_locations, public.location_stock, public.location_movements,
  public.transfers, public.transfer_items, public.transfer_events to authenticated;
grant insert, update on public.locations to authenticated;
revoke delete on public.locations from authenticated;

create policy locations_select on public.locations for select to authenticated using (public.is_staff());
create policy locations_insert on public.locations for insert to authenticated with check (public.has_role('owner'));
create policy locations_update on public.locations for update to authenticated
  using (public.has_role('owner')) with check (public.has_role('owner'));
create policy staff_locations_select on public.staff_locations for select to authenticated
  using (public.is_manager() or profile_id = auth.uid());
create policy location_stock_select on public.location_stock for select to authenticated using (public.is_staff());
create policy location_movements_select on public.location_movements for select to authenticated using (public.is_manager());
create policy transfers_select on public.transfers for select to authenticated
  using (public.is_manager() or (public.is_staff() and public._my_location() in (from_location, to_location)));
create policy transfer_items_select on public.transfer_items for select to authenticated
  using (exists (select 1 from public.transfers t where t.id = transfer_id));
create policy transfer_events_select on public.transfer_events for select to authenticated
  using (exists (select 1 from public.transfers t where t.id = transfer_id));

create trigger locations_audit after insert or update or delete on public.locations
  for each row execute function public.audit_trigger();
create trigger staff_locations_audit after insert or update or delete on public.staff_locations
  for each row execute function public.audit_trigger();
create trigger transfers_audit after insert or update or delete on public.transfers
  for each row execute function public.audit_trigger();
create trigger transfer_items_audit after insert or update or delete on public.transfer_items
  for each row execute function public.audit_trigger();

-- الدوال الداخلية لا تُستدعى مباشرة
revoke all on function
  public._default_location(), public._transit_location(), public._my_location(), public._multi_location(),
  public._best_other_location(uuid, uuid),
  public._apply_location(uuid, uuid, integer, public.loc_movement_type, bigint, uuid, uuid, text, boolean),
  public.attribute_stock_movement(), public._check_location_invariant(uuid),
  public.location_stock_invariant(), public.variant_stock_invariant(),
  public.shift_set_location(), public.purchase_set_location(), public._op_seen(uuid, text, uuid),
  public._outgoing_pending(uuid, uuid, uuid), public._can_act_at(uuid), public._transfer_refresh(uuid, boolean),
  public.locations_guard()
from public, anon, authenticated;
-- تستخدمها سياسة transfers_select وتعيد موقع المستخدم نفسه فقط
grant execute on function public._my_location() to authenticated;

revoke execute on function
  public.adjust_location_stock(uuid, uuid, integer, text, uuid),
  public.request_transfer(uuid, uuid, jsonb, text, uuid),
  public.approve_transfer(uuid, jsonb, text),
  public.close_transfer(uuid, text, boolean),
  public.ship_transfer(uuid, jsonb, boolean, uuid),
  public.receive_transfer(uuid, jsonb, boolean, uuid),
  public.resolve_transfer_loss(uuid, uuid, integer, text, uuid),
  public.set_staff_location(uuid, uuid)
from public, anon;
grant execute on function
  public.adjust_location_stock(uuid, uuid, integer, text, uuid),
  public.request_transfer(uuid, uuid, jsonb, text, uuid),
  public.approve_transfer(uuid, jsonb, text),
  public.close_transfer(uuid, text, boolean),
  public.ship_transfer(uuid, jsonb, boolean, uuid),
  public.receive_transfer(uuid, jsonb, boolean, uuid),
  public.resolve_transfer_loss(uuid, uuid, integer, text, uuid),
  public.set_staff_location(uuid, uuid)
to authenticated;
commit;
