-- ملف مُولَّد تلقائياً من supabase/migrations — لا تعدّله يدوياً (npm run db:bundle)
-- نفّذه مرة واحدة فقط على مشروع Supabase جديد، في SQL Editor.
-- يحتوي: 0001_schema.sql, 0002_triggers_audit.sql, 0003_rls.sql, 0004_functions.sql, 0005_storage_limits.sql, 0006_shifts.sql, 0007_expenses.sql, 0008_purchase_advisor.sql, 0013_locations_transfers.sql, 0014_smart_counts.sql, 0015_inventory_intelligence.sql, 0016_decision_center.sql

begin;

-- =====================================================================
-- 0001_schema.sql
-- =====================================================================
-- =====================================================================
-- نظام نقاط البيع لمحلات الملابس — المخطط الأساسي
-- PostgreSQL / Supabase
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
create type public.user_role as enum ('owner', 'manager', 'cashier');
create type public.payment_method as enum ('cash', 'card', 'transfer', 'exchange_credit');
create type public.refund_method as enum ('cash', 'card', 'transfer', 'exchange');
create type public.sale_status as enum ('completed', 'partially_returned', 'returned');
create type public.purchase_status as enum ('draft', 'ordered', 'received', 'cancelled');
create type public.movement_type as enum ('opening', 'sale', 'return', 'purchase', 'adjustment', 'count');
create type public.count_status as enum ('open', 'applied', 'cancelled');

-- ---------------------------------------------------------------------
-- Settings (single row)
-- ---------------------------------------------------------------------
create table public.store_settings (
  id smallint primary key default 1 check (id = 1),
  store_name text not null default 'متجر الملابس',
  store_name_en text,
  vat_number text,
  cr_number text,
  phone text,
  address text,
  logo_url text,
  receipt_footer text default 'شكراً لتسوقكم معنا — الاستبدال خلال 7 أيام والاسترجاع خلال 3 أيام بالفاتورة',
  vat_rate numeric(5,2) not null default 15.00 check (vat_rate >= 0 and vat_rate <= 100),
  prices_include_vat boolean not null default true,
  allow_negative_stock boolean not null default false,
  allow_cashier_returns boolean not null default true,
  max_cashier_discount_pct numeric(5,2) not null default 10 check (max_cashier_discount_pct between 0 and 100),
  return_days smallint not null default 7,
  currency text not null default 'SAR',
  updated_at timestamptz not null default now()
);
insert into public.store_settings (id) values (1);

-- ---------------------------------------------------------------------
-- Profiles & roles
-- ---------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  email text,
  phone text,
  role public.user_role not null default 'cashier',
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- الدور الحالي للمستخدم (NULL إذا غير مفعل)
create or replace function public.current_user_role()
returns public.user_role
language sql stable security definer set search_path = public
as $$
  select role from public.profiles where id = auth.uid() and is_active
$$;

create or replace function public.has_role(variadic roles public.user_role[])
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_user_role() = any (roles), false)
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.current_user_role() is not null
$$;

create or replace function public.is_manager()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.has_role('owner', 'manager')
$$;

-- إنشاء الملف الشخصي تلقائياً عند التسجيل.
-- أول مستخدم يصبح المالك. المستخدمون الذين ينشئهم المالك (app_metadata.role) يُفعّلون مباشرة.
-- أي تسجيل ذاتي آخر يبقى غير مفعل حتى يعتمده المالك.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_is_first boolean;
  v_role public.user_role;
  v_active boolean;
begin
  select not exists (select 1 from public.profiles) into v_is_first;
  if v_is_first then
    v_role := 'owner'; v_active := true;
  elsif new.raw_app_meta_data ? 'role' then
    v_role := (new.raw_app_meta_data ->> 'role')::public.user_role; v_active := true;
  else
    v_role := 'cashier'; v_active := false;
  end if;

  insert into public.profiles (id, full_name, email, role, is_active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email, v_role, v_active
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- الدور المحدد من المالك عبر Admin API (app_metadata.role).
-- GoTrue يكتب app_metadata بتحديث لاحق للإدراج، لذلك نزامن عند التحديث أيضاً.
create or replace function public.sync_user_role()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.raw_app_meta_data ? 'role'
     and (new.raw_app_meta_data ->> 'role') is distinct from (old.raw_app_meta_data ->> 'role') then
    update public.profiles
       set role = (new.raw_app_meta_data ->> 'role')::public.user_role, is_active = true
     where id = new.id;
  end if;
  return new;
end;
$$;

create trigger on_auth_user_role_updated
  after update of raw_app_meta_data on auth.users
  for each row execute function public.sync_user_role();

-- منع تغيير الدور أو التفعيل من التطبيق إلا من المالك، ومنع المالك من تغيير صلاحيته.
-- (ليست security definer عمداً: current_user هنا هو دور المتصل الفعلي)
create or replace function public.guard_profile_update()
returns trigger
language plpgsql
as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.role is distinct from old.role or new.is_active is distinct from old.is_active) then
    if not public.has_role('owner') then
      raise exception 'فقط المالك يمكنه تغيير الصلاحيات';
    end if;
    if old.id = auth.uid() then
      raise exception 'لا يمكنك تغيير صلاحيتك بنفسك';
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_update();

-- ---------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  name_en text,
  category_id uuid references public.categories (id) on delete set null,
  brand text,
  description text,
  image_url text,
  base_price numeric(12,2) not null check (base_price >= 0),
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index products_category_idx on public.products (category_id);
create index products_name_idx on public.products using gin (to_tsvector('simple', name || ' ' || coalesce(name_en, '')));

create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  sku text not null unique,
  barcode text unique,
  size text,
  color text,
  color_hex text,
  price numeric(12,2) check (price is null or price >= 0), -- NULL = سعر المنتج الأساسي
  stock_qty integer not null default 0,
  low_stock_threshold integer not null default 3,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, size, color)
);
create index variants_product_idx on public.product_variants (product_id);

-- التكلفة في جدول منفصل حتى لا يراها الكاشير (RLS للمدير والمالك فقط)
create table public.variant_costs (
  variant_id uuid primary key references public.product_variants (id) on delete cascade,
  cost_price numeric(12,2) not null default 0 check (cost_price >= 0),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Customers & suppliers
-- ---------------------------------------------------------------------
create table public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text unique,
  email text,
  vat_number text,
  city text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  contact_name text,
  phone text,
  email text,
  vat_number text,
  address text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------------
create sequence public.invoice_seq start 1;
create sequence public.return_seq start 1;
create sequence public.purchase_seq start 1;
create sequence public.count_seq start 1;

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  invoice_no text not null unique,
  customer_id uuid references public.customers (id) on delete set null,
  cashier_id uuid not null references public.profiles (id),
  subtotal numeric(12,2) not null,          -- قبل الضريبة وبعد الخصم
  discount_total numeric(12,2) not null default 0,
  invoice_discount numeric(12,2) not null default 0,
  vat_rate numeric(5,2) not null,
  vat_amount numeric(12,2) not null,
  total numeric(12,2) not null,             -- شامل الضريبة
  paid_amount numeric(12,2) not null,
  change_amount numeric(12,2) not null default 0,
  returned_amount numeric(12,2) not null default 0,
  status public.sale_status not null default 'completed',
  notes text,
  created_at timestamptz not null default now()
);
create index sales_created_idx on public.sales (created_at desc);
create index sales_cashier_idx on public.sales (cashier_id, created_at desc);
create index sales_customer_idx on public.sales (customer_id);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id),
  product_name text not null,
  variant_label text,
  sku text,
  qty integer not null check (qty > 0),
  unit_price numeric(12,2) not null,        -- سعر الوحدة كما في الكتالوج
  line_discount numeric(12,2) not null default 0,  -- خصم السطر + حصته من خصم الفاتورة
  line_total numeric(12,2) not null,        -- شامل الضريبة بعد الخصم
  vat_amount numeric(12,2) not null,
  unit_cost numeric(12,2) not null default 0,
  returned_qty integer not null default 0 check (returned_qty >= 0),
  constraint returned_le_qty check (returned_qty <= qty)
);
create index sale_items_sale_idx on public.sale_items (sale_id);
create index sale_items_variant_idx on public.sale_items (variant_id);

create table public.returns (
  id uuid primary key default gen_random_uuid(),
  return_no text not null unique,
  sale_id uuid not null references public.sales (id),
  cashier_id uuid not null references public.profiles (id),
  refund_method public.refund_method not null,
  total numeric(12,2) not null,
  vat_amount numeric(12,2) not null,
  reason text,
  credit_used_by_sale uuid references public.sales (id),
  created_at timestamptz not null default now()
);
create index returns_sale_idx on public.returns (sale_id);

create table public.sale_payments (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete cascade,
  method public.payment_method not null,
  amount numeric(12,2) not null check (amount > 0),
  reference text,
  exchange_return_id uuid references public.returns (id),
  created_at timestamptz not null default now()
);
create index sale_payments_sale_idx on public.sale_payments (sale_id);

create table public.return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.returns (id) on delete cascade,
  sale_item_id uuid not null references public.sale_items (id),
  variant_id uuid not null references public.product_variants (id),
  qty integer not null check (qty > 0),
  amount numeric(12,2) not null,
  vat_amount numeric(12,2) not null,
  restocked boolean not null default true
);
create index return_items_return_idx on public.return_items (return_id);

-- ---------------------------------------------------------------------
-- Purchasing
-- ---------------------------------------------------------------------
create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  po_no text not null unique,
  supplier_id uuid not null references public.suppliers (id),
  status public.purchase_status not null default 'draft',
  supplier_invoice_no text,
  subtotal numeric(12,2) not null default 0,
  vat_amount numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  notes text,
  created_by uuid references public.profiles (id) default auth.uid(),
  received_by uuid references public.profiles (id),
  received_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchase_orders (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id),
  qty integer not null check (qty > 0),
  unit_cost numeric(12,2) not null check (unit_cost >= 0) -- قبل الضريبة
);
create index purchase_items_po_idx on public.purchase_items (purchase_id);

-- ---------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------
create table public.stock_movements (
  id bigint generated always as identity primary key,
  variant_id uuid not null references public.product_variants (id) on delete cascade,
  type public.movement_type not null,
  qty_change integer not null,
  balance_after integer not null,
  ref_id uuid,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index stock_movements_variant_idx on public.stock_movements (variant_id, created_at desc);
create index stock_movements_created_idx on public.stock_movements (created_at desc);

create table public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  count_no text not null unique,
  status public.count_status not null default 'open',
  category_id uuid references public.categories (id),
  notes text,
  created_by uuid references public.profiles (id) default auth.uid(),
  applied_by uuid references public.profiles (id),
  applied_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.stock_count_items (
  id uuid primary key default gen_random_uuid(),
  count_id uuid not null references public.stock_counts (id) on delete cascade,
  variant_id uuid not null references public.product_variants (id) on delete cascade,
  expected_qty integer not null,
  counted_qty integer check (counted_qty is null or counted_qty >= 0),
  counted_by uuid references public.profiles (id),
  counted_at timestamptz,
  unique (count_id, variant_id)
);

-- ---------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------
create table public.audit_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id text,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data jsonb,
  new_data jsonb,
  changed_fields text[],
  actor_id uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index audit_log_created_idx on public.audit_log (created_at desc);
create index audit_log_table_idx on public.audit_log (table_name, record_id);

-- =====================================================================
-- 0002_triggers_audit.sql
-- =====================================================================
-- =====================================================================
-- Triggers: updated_at, حماية المخزون، سجل التدقيق
-- =====================================================================

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger products_touch before update on public.products
  for each row execute function public.touch_updated_at();
create trigger customers_touch before update on public.customers
  for each row execute function public.touch_updated_at();
create trigger suppliers_touch before update on public.suppliers
  for each row execute function public.touch_updated_at();
create trigger purchase_orders_touch before update on public.purchase_orders
  for each row execute function public.touch_updated_at();
create trigger store_settings_touch before update on public.store_settings
  for each row execute function public.touch_updated_at();
create trigger variant_costs_touch before update on public.variant_costs
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- المخزون لا يتغير إلا عبر دوال النظام (مبيعات/مرتجعات/مشتريات/تسويات/جرد)
-- ---------------------------------------------------------------------
create or replace function public.guard_variant_stock()
returns trigger language plpgsql as $$
begin
  if new.stock_qty is distinct from old.stock_qty
     and coalesce(current_setting('app.stock_rpc', true), '') <> 'on' then
    raise exception 'لا يمكن تعديل الكمية مباشرة — استخدم تسوية المخزون أو الجرد';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger variants_guard_stock before update on public.product_variants
  for each row execute function public.guard_variant_stock();

-- رصيد افتتاحي + سجل تكلفة عند إنشاء مقاس/لون جديد
create or replace function public.on_variant_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.variant_costs (variant_id, cost_price)
  values (new.id, 0) on conflict (variant_id) do nothing;

  if new.stock_qty <> 0 then
    insert into public.stock_movements (variant_id, type, qty_change, balance_after, note)
    values (new.id, 'opening', new.stock_qty, new.stock_qty, 'رصيد افتتاحي');
  end if;
  return new;
end;
$$;

create trigger variants_after_insert after insert on public.product_variants
  for each row execute function public.on_variant_created();

-- تحريك المخزون (داخلي — تستدعيه الدوال فقط)
create or replace function public._move_stock(
  p_variant_id uuid,
  p_qty_change integer,
  p_type public.movement_type,
  p_ref_id uuid,
  p_note text,
  p_check_negative boolean default false
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_balance integer;
begin
  perform set_config('app.stock_rpc', 'on', true);

  update public.product_variants
     set stock_qty = stock_qty + p_qty_change
   where id = p_variant_id
  returning stock_qty into v_balance;

  if v_balance is null then
    raise exception 'الصنف غير موجود';
  end if;

  if p_check_negative and v_balance < 0 then
    raise exception 'الكمية غير متوفرة في المخزون (الصنف %)', (select sku from public.product_variants where id = p_variant_id);
  end if;

  insert into public.stock_movements (variant_id, type, qty_change, balance_after, ref_id, note)
  values (p_variant_id, p_type, p_qty_change, v_balance, p_ref_id, p_note);

  perform set_config('app.stock_rpc', 'off', true);
  return v_balance;
end;
$$;
revoke all on function public._move_stock(uuid, integer, public.movement_type, uuid, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- إجماليات أمر الشراء
-- ---------------------------------------------------------------------
create or replace function public.recalc_purchase_totals()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_po uuid := coalesce(new.purchase_id, old.purchase_id);
  v_rate numeric := (select vat_rate from public.store_settings where id = 1);
  v_sub numeric;
begin
  select coalesce(sum(qty * unit_cost), 0) into v_sub
    from public.purchase_items where purchase_id = v_po;
  update public.purchase_orders
     set subtotal = round(v_sub, 2),
         vat_amount = round(v_sub * v_rate / 100, 2),
         total = round(v_sub, 2) + round(v_sub * v_rate / 100, 2)
   where id = v_po;
  return null;
end;
$$;

create trigger purchase_items_totals after insert or update or delete on public.purchase_items
  for each row execute function public.recalc_purchase_totals();

-- ---------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_changed text[];
begin
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;

  if tg_op = 'UPDATE' then
    select array_agg(n.key order by n.key) into v_changed
      from jsonb_each(v_new) n
     where n.value is distinct from (v_old -> n.key)
       and n.key not in ('updated_at', 'stock_qty');
    -- تغيّر المخزون فقط مسجل في حركات المخزون، لا داعي لتكراره
    if v_changed is null then
      return new;
    end if;
  end if;

  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed_fields)
  values (
    tg_table_name,
    coalesce(v_new ->> 'id', v_old ->> 'id', v_new ->> 'variant_id', v_old ->> 'variant_id'),
    tg_op, v_old, v_new, v_changed
  );
  return coalesce(new, old);
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'store_settings', 'profiles', 'categories', 'products', 'product_variants',
    'variant_costs', 'customers', 'suppliers', 'sales', 'sale_payments', 'returns',
    'purchase_orders', 'purchase_items', 'stock_counts'
  ] loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I
         for each row execute function public.audit_trigger()',
      t || '_audit', t);
  end loop;
end;
$$;

-- =====================================================================
-- 0003_rls.sql
-- =====================================================================
-- =====================================================================
-- Row Level Security
--   owner   : كل شيء
--   manager : المنتجات، المخزون، المشتريات، الموردين، التقارير، كل المبيعات
--   cashier : البيع، العملاء، مبيعاته فقط، الجرد (إدخال الكميات)
-- عمليات البيع والمرتجع والمخزون تتم فقط عبر دوال RPC (security definer)
-- =====================================================================

alter table public.store_settings enable row level security;
alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.variant_costs enable row level security;
alter table public.customers enable row level security;
alter table public.suppliers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.sale_payments enable row level security;
alter table public.returns enable row level security;
alter table public.return_items enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_items enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_counts enable row level security;
alter table public.stock_count_items enable row level security;
alter table public.audit_log enable row level security;

-- صلاحيات صريحة: لا نعتمد على الصلاحيات الافتراضية للمشروع (تختلف بين مشاريع Supabase)
-- RLS أدناه هي التي تحدد الصفوف المسموحة فعلياً لكل دور
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- لا شيء للزوار غير المسجلين
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

-- جداول تُكتب فقط عبر الدوال
revoke insert, update, delete on public.sales, public.sale_items, public.sale_payments,
  public.returns, public.return_items, public.stock_movements, public.audit_log
  from authenticated;

-- الكاشير لا يرى تكلفة الأصناف المباعة: منح القراءة على الأعمدة دون unit_cost
revoke select on public.sale_items from authenticated;
grant select (id, sale_id, variant_id, product_name, variant_label, sku, qty, unit_price,
  line_discount, line_total, vat_amount, returned_qty) on public.sale_items to authenticated;

-- الجرد: الموظف يعدّل الكمية المعدودة فقط
revoke update on public.stock_count_items from authenticated;
grant update (counted_qty, counted_by, counted_at) on public.stock_count_items to authenticated;
revoke insert, delete on public.stock_count_items from authenticated;
revoke insert, delete on public.stock_counts from authenticated;

-- ---------------------------------------------------------------------
-- store_settings
-- ---------------------------------------------------------------------
create policy settings_select on public.store_settings for select to authenticated
  using (public.is_staff());
create policy settings_update on public.store_settings for update to authenticated
  using (public.has_role('owner')) with check (public.has_role('owner'));

-- ---------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_manager());
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_update_owner on public.profiles for update to authenticated
  using (public.has_role('owner')) with check (public.has_role('owner'));

-- ---------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------
create policy categories_select on public.categories for select to authenticated
  using (public.is_staff());
create policy categories_write on public.categories for all to authenticated
  using (public.is_manager()) with check (public.is_manager());

create policy products_select on public.products for select to authenticated
  using (public.is_staff());
create policy products_insert on public.products for insert to authenticated
  with check (public.is_manager());
create policy products_update on public.products for update to authenticated
  using (public.is_manager()) with check (public.is_manager());
create policy products_delete on public.products for delete to authenticated
  using (public.has_role('owner'));

create policy variants_select on public.product_variants for select to authenticated
  using (public.is_staff());
create policy variants_insert on public.product_variants for insert to authenticated
  with check (public.is_manager());
create policy variants_update on public.product_variants for update to authenticated
  using (public.is_manager()) with check (public.is_manager());
create policy variants_delete on public.product_variants for delete to authenticated
  using (public.has_role('owner'));

create policy variant_costs_all on public.variant_costs for all to authenticated
  using (public.is_manager()) with check (public.is_manager());

-- ---------------------------------------------------------------------
-- Customers / suppliers
-- ---------------------------------------------------------------------
create policy customers_select on public.customers for select to authenticated
  using (public.is_staff());
create policy customers_insert on public.customers for insert to authenticated
  with check (public.is_staff());
create policy customers_update on public.customers for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy customers_delete on public.customers for delete to authenticated
  using (public.is_manager());

create policy suppliers_all on public.suppliers for all to authenticated
  using (public.is_manager()) with check (public.is_manager());

-- ---------------------------------------------------------------------
-- Sales & returns (قراءة فقط — الكتابة عبر RPC)
-- ---------------------------------------------------------------------
create policy sales_select on public.sales for select to authenticated
  using (public.is_manager() or (public.is_staff() and cashier_id = auth.uid()));
create policy sale_items_select on public.sale_items for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id));
create policy sale_payments_select on public.sale_payments for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id));

create policy returns_select on public.returns for select to authenticated
  using (public.is_manager() or (public.is_staff() and cashier_id = auth.uid()));
create policy return_items_select on public.return_items for select to authenticated
  using (exists (select 1 from public.returns r where r.id = return_id));

-- ---------------------------------------------------------------------
-- Purchasing
-- ---------------------------------------------------------------------
create policy po_select on public.purchase_orders for select to authenticated
  using (public.is_manager());
create policy po_insert on public.purchase_orders for insert to authenticated
  with check (public.is_manager() and status in ('draft', 'ordered'));
create policy po_update on public.purchase_orders for update to authenticated
  using (public.is_manager() and status in ('draft', 'ordered'))
  with check (public.is_manager() and status in ('draft', 'ordered', 'cancelled'));
create policy po_delete on public.purchase_orders for delete to authenticated
  using (public.is_manager() and status = 'draft');

create policy pi_select on public.purchase_items for select to authenticated
  using (public.is_manager());
create policy pi_write on public.purchase_items for all to authenticated
  using (public.is_manager() and exists (
    select 1 from public.purchase_orders po
     where po.id = purchase_id and po.status in ('draft', 'ordered')))
  with check (public.is_manager() and exists (
    select 1 from public.purchase_orders po
     where po.id = purchase_id and po.status in ('draft', 'ordered')));

-- ---------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------
create policy movements_select on public.stock_movements for select to authenticated
  using (public.is_manager());

create policy counts_select on public.stock_counts for select to authenticated
  using (public.is_staff());
create policy counts_update on public.stock_counts for update to authenticated
  using (public.is_manager() and status = 'open')
  with check (public.is_manager());

create policy count_items_select on public.stock_count_items for select to authenticated
  using (public.is_staff());
create policy count_items_update on public.stock_count_items for update to authenticated
  using (public.is_staff() and exists (
    select 1 from public.stock_counts c where c.id = count_id and c.status = 'open'))
  with check (public.is_staff());

-- ---------------------------------------------------------------------
-- Audit log: المالك فقط
-- ---------------------------------------------------------------------
create policy audit_select on public.audit_log for select to authenticated
  using (public.has_role('owner'));

-- ---------------------------------------------------------------------
-- Storage: صور المنتجات
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

create policy "product images read" on storage.objects for select
  using (bucket_id = 'product-images');
create policy "product images insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_manager());
create policy "product images update" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_manager());
create policy "product images delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_manager());

-- =====================================================================
-- 0004_functions.sql
-- =====================================================================
-- =====================================================================
-- دوال العمليات (RPC) — كل عملية مالية أو مخزنية ذرّية وتتحقق من الصلاحيات
-- =====================================================================

-- ---------------------------------------------------------------------
-- إتمام عملية بيع
-- p_items    : [{ "variant_id": uuid, "qty": int, "discount": numeric }]
--              discount = خصم السطر بنفس أساس السعر (شامل/غير شامل الضريبة حسب الإعداد)
-- p_payments : [{ "method": "cash|card|transfer|exchange_credit", "amount": numeric,
--                 "reference": text, "return_id": uuid }]
-- الأسعار تُقرأ من قاعدة البيانات وليس من المتصفح
-- ---------------------------------------------------------------------
create or replace function public.complete_sale(
  p_items jsonb,
  p_payments jsonb,
  p_customer_id uuid default null,
  p_invoice_discount numeric default 0,
  p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_sale_id uuid;
  v_item jsonb;
  v_pay jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_variant record;
  v_qty integer;
  v_price numeric;
  v_gross numeric;
  v_disc numeric;
  v_sum_gross numeric := 0;
  v_sum_line_disc numeric := 0;
  v_sum_base numeric;
  v_inv_disc numeric;
  v_alloc numeric;
  v_alloc_done numeric := 0;
  v_net numeric;
  v_line_total numeric;
  v_line_vat numeric;
  v_total numeric := 0;
  v_vat numeric := 0;
  v_paid numeric := 0;
  v_cash numeric := 0;
  v_noncash numeric := 0;
  v_change numeric;
  v_method public.payment_method;
  v_amount numeric;
  v_return public.returns;
  v_count integer;
  v_idx integer := 0;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.store_settings where id = 1;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'السلة فارغة';
  end if;
  v_count := jsonb_array_length(p_items);

  -- المرور الأول: التحقق وحساب الإجمالي قبل خصم الفاتورة
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      raise exception 'كمية غير صحيحة';
    end if;

    select v.id, v.sku, v.size, v.color, coalesce(v.price, p.base_price) as price,
           p.name, v.is_active and p.is_active as active,
           coalesce(c.cost_price, 0) as cost
      into v_variant
      from public.product_variants v
      join public.products p on p.id = v.product_id
      left join public.variant_costs c on c.variant_id = v.id
     where v.id = (v_item ->> 'variant_id')::uuid;

    if v_variant.id is null then
      raise exception 'صنف غير موجود';
    end if;
    if not v_variant.active then
      raise exception 'الصنف % موقوف', v_variant.sku;
    end if;

    v_gross := round(v_variant.price * v_qty, 2);
    v_disc := least(greatest(coalesce((v_item ->> 'discount')::numeric, 0), 0), v_gross);
    v_sum_gross := v_sum_gross + v_gross;
    v_sum_line_disc := v_sum_line_disc + v_disc;

    v_lines := v_lines || jsonb_build_object(
      'variant_id', v_variant.id,
      'sku', v_variant.sku,
      'product_name', v_variant.name,
      'variant_label', nullif(concat_ws(' / ', v_variant.size, v_variant.color), ''),
      'qty', v_qty,
      'unit_price', v_variant.price,
      'gross', v_gross,
      'disc', round(v_disc, 2),
      'cost', v_variant.cost
    );
  end loop;

  v_sum_base := v_sum_gross - v_sum_line_disc;
  v_inv_disc := round(least(greatest(coalesce(p_invoice_discount, 0), 0), v_sum_base), 2);

  -- حد الخصم للكاشير
  if v_role = 'cashier' and v_sum_gross > 0
     and (v_sum_line_disc + v_inv_disc) / v_sum_gross * 100 > s.max_cashier_discount_pct + 0.001 then
    raise exception 'الخصم يتجاوز الحد المسموح للكاشير (% %%)', s.max_cashier_discount_pct;
  end if;

  -- المرور الثاني: توزيع خصم الفاتورة وحساب الضريبة لكل سطر
  for v_idx in 0 .. v_count - 1 loop
    v_line := v_lines -> v_idx;
    v_net := (v_line ->> 'gross')::numeric - (v_line ->> 'disc')::numeric;
    if v_idx = v_count - 1 then
      v_alloc := v_inv_disc - v_alloc_done;
    elsif v_sum_base > 0 then
      v_alloc := round(v_inv_disc * v_net / v_sum_base, 2);
    else
      v_alloc := 0;
    end if;
    v_alloc_done := v_alloc_done + v_alloc;
    v_net := v_net - v_alloc;

    if s.prices_include_vat then
      v_line_total := round(v_net, 2);
      v_line_vat := round(v_net * s.vat_rate / (100 + s.vat_rate), 2);
    else
      v_line_vat := round(v_net * s.vat_rate / 100, 2);
      v_line_total := round(v_net, 2) + v_line_vat;
    end if;

    v_total := v_total + v_line_total;
    v_vat := v_vat + v_line_vat;
    v_lines := jsonb_set(v_lines, array[v_idx::text], v_line || jsonb_build_object(
      'line_discount', (v_line ->> 'disc')::numeric + v_alloc,
      'line_total', v_line_total,
      'vat', v_line_vat
    ));
  end loop;

  -- الدفعات
  if p_payments is null or jsonb_typeof(p_payments) <> 'array' or jsonb_array_length(p_payments) = 0 then
    raise exception 'لم يتم تحديد طريقة الدفع';
  end if;

  for v_pay in select * from jsonb_array_elements(p_payments) loop
    v_method := (v_pay ->> 'method')::public.payment_method;
    v_amount := round((v_pay ->> 'amount')::numeric, 2);
    if v_amount is null or v_amount <= 0 then
      raise exception 'مبلغ دفع غير صحيح';
    end if;
    if v_method = 'exchange_credit' then
      select * into v_return from public.returns
       where id = (v_pay ->> 'return_id')::uuid for update;
      if v_return.id is null or v_return.refund_method <> 'exchange' then
        raise exception 'رصيد الاستبدال غير صالح';
      end if;
      if v_return.credit_used_by_sale is not null then
        raise exception 'رصيد الاستبدال % مستخدم مسبقاً', v_return.return_no;
      end if;
      if v_amount <> v_return.total then
        raise exception 'يجب استخدام رصيد الاستبدال كاملاً (% ر.س)', v_return.total;
      end if;
    end if;
    if v_method = 'cash' then
      v_cash := v_cash + v_amount;
    else
      v_noncash := v_noncash + v_amount;
    end if;
    v_paid := v_paid + v_amount;
  end loop;

  if v_noncash > v_total + 0.001 then
    raise exception 'مبالغ الشبكة/التحويل/الاستبدال (% ) أكبر من إجمالي الفاتورة (% )', v_noncash, v_total;
  end if;
  if v_paid + 0.001 < v_total then
    raise exception 'المبلغ المدفوع (% ) أقل من الإجمالي (% )', v_paid, v_total;
  end if;
  v_change := round(v_paid - v_total, 2);

  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'العميل غير موجود';
  end if;

  insert into public.sales (
    invoice_no, customer_id, cashier_id, subtotal, discount_total, invoice_discount,
    vat_rate, vat_amount, total, paid_amount, change_amount, notes
  ) values (
    'INV-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.invoice_seq')::text, 6, '0'),
    p_customer_id, auth.uid(), v_total - v_vat, v_sum_line_disc + v_inv_disc, v_inv_disc,
    s.vat_rate, v_vat, v_total, v_paid, v_change, nullif(trim(p_notes), '')
  ) returning id into v_sale_id;

  insert into public.sale_items (
    sale_id, variant_id, product_name, variant_label, sku, qty, unit_price,
    line_discount, line_total, vat_amount, unit_cost
  )
  select v_sale_id, (l ->> 'variant_id')::uuid, l ->> 'product_name', l ->> 'variant_label',
         l ->> 'sku', (l ->> 'qty')::integer, (l ->> 'unit_price')::numeric,
         (l ->> 'line_discount')::numeric, (l ->> 'line_total')::numeric,
         (l ->> 'vat')::numeric, (l ->> 'cost')::numeric
    from jsonb_array_elements(v_lines) l;

  for v_line in select * from jsonb_array_elements(v_lines) loop
    perform public._move_stock(
      (v_line ->> 'variant_id')::uuid, -((v_line ->> 'qty')::integer), 'sale', v_sale_id,
      null, not s.allow_negative_stock);
  end loop;

  for v_pay in select * from jsonb_array_elements(p_payments) loop
    v_method := (v_pay ->> 'method')::public.payment_method;
    insert into public.sale_payments (sale_id, method, amount, reference, exchange_return_id)
    values (
      v_sale_id, v_method, round((v_pay ->> 'amount')::numeric, 2),
      nullif(v_pay ->> 'reference', ''),
      case when v_method = 'exchange_credit' then (v_pay ->> 'return_id')::uuid end
    );
    if v_method = 'exchange_credit' then
      update public.returns set credit_used_by_sale = v_sale_id
       where id = (v_pay ->> 'return_id')::uuid;
    end if;
  end loop;

  return v_sale_id;
end;
$$;

-- ---------------------------------------------------------------------
-- جلب فاتورة للإرجاع (بدون بيانات التكلفة)
-- ---------------------------------------------------------------------
create or replace function public.get_sale_for_return(p_invoice_no text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_sale public.sales;
begin
  select * into s from public.store_settings where id = 1;
  if v_role is null or (v_role = 'cashier' and not s.allow_cashier_returns) then
    raise exception 'غير مصرح بعمليات الإرجاع';
  end if;

  select * into v_sale from public.sales where upper(invoice_no) = upper(trim(p_invoice_no));
  if v_sale.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;

  return jsonb_build_object(
    'id', v_sale.id,
    'invoice_no', v_sale.invoice_no,
    'created_at', v_sale.created_at,
    'total', v_sale.total,
    'returned_amount', v_sale.returned_amount,
    'status', v_sale.status,
    'customer_name', (select name from public.customers where id = v_sale.customer_id),
    'days_since', (now() at time zone 'Asia/Riyadh')::date - (v_sale.created_at at time zone 'Asia/Riyadh')::date,
    'return_days', s.return_days,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'variant_id', i.variant_id, 'product_name', i.product_name,
        'variant_label', i.variant_label, 'sku', i.sku, 'qty', i.qty,
        'returned_qty', i.returned_qty, 'unit_price', i.unit_price,
        'line_total', i.line_total, 'vat_amount', i.vat_amount
      ) order by i.product_name)
      from public.sale_items i where i.sale_id = v_sale.id), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- مرتجع / استبدال
-- p_items : [{ "sale_item_id": uuid, "qty": int, "restock": bool }]
-- p_refund_method = 'exchange' ينشئ رصيد استبدال يُستخدم في فاتورة جديدة
-- ---------------------------------------------------------------------
create or replace function public.process_return(
  p_sale_id uuid,
  p_items jsonb,
  p_refund_method public.refund_method,
  p_reason text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_sale public.sales;
  v_item jsonb;
  v_si public.sale_items;
  v_qty integer;
  v_amount numeric;
  v_vat numeric;
  v_prev_amount numeric;
  v_prev_vat numeric;
  v_total numeric := 0;
  v_total_vat numeric := 0;
  v_return_id uuid;
  v_restock boolean;
  v_remaining integer;
begin
  select * into s from public.store_settings where id = 1;
  if v_role is null or (v_role = 'cashier' and not s.allow_cashier_returns) then
    raise exception 'غير مصرح بعمليات الإرجاع';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  if v_sale.status = 'returned' then
    raise exception 'الفاتورة مرتجعة بالكامل';
  end if;
  if v_role = 'cashier'
     and (now() at time zone 'Asia/Riyadh')::date - (v_sale.created_at at time zone 'Asia/Riyadh')::date > s.return_days then
    raise exception 'انتهت مدة الإرجاع (% أيام) — يحتاج موافقة المدير', s.return_days;
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'لم يتم اختيار أصناف للإرجاع';
  end if;

  insert into public.returns (return_no, sale_id, cashier_id, refund_method, total, vat_amount, reason)
  values (
    'RET-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.return_seq')::text, 6, '0'),
    p_sale_id, auth.uid(), p_refund_method, 0, 0, nullif(trim(p_reason), '')
  ) returning id into v_return_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      continue;
    end if;
    v_restock := coalesce((v_item ->> 'restock')::boolean, true);

    select * into v_si from public.sale_items
     where id = (v_item ->> 'sale_item_id')::uuid and sale_id = p_sale_id for update;
    if v_si.id is null then
      raise exception 'صنف غير موجود في الفاتورة';
    end if;
    v_remaining := v_si.qty - v_si.returned_qty;
    if v_qty > v_remaining then
      raise exception 'الكمية المرتجعة للصنف % أكبر من المتبقي (%)', v_si.sku, v_remaining;
    end if;

    if v_qty = v_remaining then
      -- آخر كمية: نرجع المتبقي بالضبط لتجنب فروقات التقريب
      select coalesce(sum(amount), 0), coalesce(sum(vat_amount), 0)
        into v_prev_amount, v_prev_vat
        from public.return_items where sale_item_id = v_si.id;
      v_amount := v_si.line_total - v_prev_amount;
      v_vat := v_si.vat_amount - v_prev_vat;
    else
      v_amount := round(v_si.line_total * v_qty / v_si.qty, 2);
      v_vat := round(v_si.vat_amount * v_qty / v_si.qty, 2);
    end if;

    insert into public.return_items (return_id, sale_item_id, variant_id, qty, amount, vat_amount, restocked)
    values (v_return_id, v_si.id, v_si.variant_id, v_qty, v_amount, v_vat, v_restock);

    update public.sale_items set returned_qty = returned_qty + v_qty where id = v_si.id;

    if v_restock then
      perform public._move_stock(v_si.variant_id, v_qty, 'return', v_return_id, v_sale.invoice_no, false);
    end if;

    v_total := v_total + v_amount;
    v_total_vat := v_total_vat + v_vat;
  end loop;

  if v_total <= 0 then
    raise exception 'لم يتم اختيار أصناف للإرجاع';
  end if;

  update public.returns set total = v_total, vat_amount = v_total_vat where id = v_return_id;

  update public.sales
     set returned_amount = returned_amount + v_total,
         status = case
           when not exists (select 1 from public.sale_items where sale_id = p_sale_id and returned_qty < qty)
             then 'returned'::public.sale_status
           else 'partially_returned'::public.sale_status end
   where id = p_sale_id;

  return v_return_id;
end;
$$;

-- ---------------------------------------------------------------------
-- تسوية المخزون (زيادة/نقص) — مدير أو مالك
-- ---------------------------------------------------------------------
create or replace function public.adjust_stock(p_variant_id uuid, p_qty_change integer, p_note text)
returns integer
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_qty_change = 0 then
    raise exception 'الكمية يجب ألا تكون صفراً';
  end if;
  if coalesce(trim(p_note), '') = '' then
    raise exception 'سبب التسوية مطلوب';
  end if;
  return public._move_stock(p_variant_id, p_qty_change, 'adjustment', null, p_note, false);
end;
$$;

-- ---------------------------------------------------------------------
-- استلام أمر شراء: زيادة المخزون وتحديث متوسط التكلفة المرجح
-- ---------------------------------------------------------------------
create or replace function public.receive_purchase(p_purchase_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_po public.purchase_orders;
  v_item record;
  v_old_qty integer;
  v_old_cost numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  select * into v_po from public.purchase_orders where id = p_purchase_id for update;
  if v_po.id is null then
    raise exception 'أمر الشراء غير موجود';
  end if;
  if v_po.status not in ('draft', 'ordered') then
    raise exception 'لا يمكن استلام أمر شراء بحالة %', v_po.status;
  end if;
  if not exists (select 1 from public.purchase_items where purchase_id = p_purchase_id) then
    raise exception 'أمر الشراء لا يحتوي أصنافاً';
  end if;

  for v_item in select * from public.purchase_items where purchase_id = p_purchase_id loop
    select greatest(v.stock_qty, 0), coalesce(c.cost_price, 0)
      into v_old_qty, v_old_cost
      from public.product_variants v
      left join public.variant_costs c on c.variant_id = v.id
     where v.id = v_item.variant_id for update of v;

    insert into public.variant_costs (variant_id, cost_price)
    values (
      v_item.variant_id,
      case when v_old_qty + v_item.qty > 0
        then round((v_old_qty * v_old_cost + v_item.qty * v_item.unit_cost) / (v_old_qty + v_item.qty), 2)
        else v_item.unit_cost end
    )
    on conflict (variant_id) do update set cost_price = excluded.cost_price;

    perform public._move_stock(v_item.variant_id, v_item.qty, 'purchase', p_purchase_id, v_po.po_no, false);
  end loop;

  update public.purchase_orders
     set status = 'received', received_at = now(), received_by = auth.uid()
   where id = p_purchase_id;
end;
$$;

create or replace function public.next_po_no()
returns text
language sql security definer set search_path = public as $$
  select 'PO-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.purchase_seq')::text, 5, '0')
$$;

-- ---------------------------------------------------------------------
-- الجرد
-- ---------------------------------------------------------------------
create or replace function public.start_stock_count(p_category_id uuid default null, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  insert into public.stock_counts (count_no, category_id, notes)
  values (
    'CNT-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.count_seq')::text, 4, '0'),
    p_category_id, nullif(trim(p_notes), '')
  ) returning id into v_id;

  insert into public.stock_count_items (count_id, variant_id, expected_qty)
  select v_id, v.id, v.stock_qty
    from public.product_variants v
    join public.products p on p.id = v.product_id
   where v.is_active and p.is_active
     and (p_category_id is null or p.category_id = p_category_id);

  return v_id;
end;
$$;

-- الاعتماد: تُضبط كمية كل صنف معدود على الكمية المعدودة
create or replace function public.apply_stock_count(p_count_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_count public.stock_counts;
  v_item record;
  v_changed integer := 0;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  select * into v_count from public.stock_counts where id = p_count_id for update;
  if v_count.id is null or v_count.status <> 'open' then
    raise exception 'الجرد غير موجود أو مغلق';
  end if;

  for v_item in
    select i.variant_id, i.counted_qty, v.stock_qty
      from public.stock_count_items i
      join public.product_variants v on v.id = i.variant_id
     where i.count_id = p_count_id and i.counted_qty is not null
       and i.counted_qty <> v.stock_qty
       for update of v
  loop
    perform public._move_stock(
      v_item.variant_id, v_item.counted_qty - v_item.stock_qty, 'count', p_count_id, v_count.count_no, false);
    v_changed := v_changed + 1;
  end loop;

  update public.stock_counts
     set status = 'applied', applied_at = now(), applied_by = auth.uid()
   where id = p_count_id;

  return v_changed;
end;
$$;

-- ---------------------------------------------------------------------
-- لوحة التحكم
-- ---------------------------------------------------------------------
create or replace function public.dashboard_stats()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_month date := date_trunc('month', v_today)::date;
  v_result jsonb;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  with
  s as (
    select id, total, vat_amount, change_amount, (created_at at time zone 'Asia/Riyadh')::date as d
      from public.sales
     where created_at >= (v_today - 30)::timestamp at time zone 'Asia/Riyadh'
        or created_at >= v_month::timestamp at time zone 'Asia/Riyadh'
  ),
  r as (
    select id, total, vat_amount, (created_at at time zone 'Asia/Riyadh')::date as d
      from public.returns
     where created_at >= least(v_today - 30, v_month)::timestamp at time zone 'Asia/Riyadh'
  ),
  si as (
    select s.d, sum(i.line_total - i.vat_amount - i.unit_cost * i.qty) as profit
      from public.sale_items i join s on s.id = i.sale_id group by s.d
  ),
  ri as (
    select r.d, sum(rit.amount - rit.vat_amount - sit.unit_cost * rit.qty) as profit
      from public.return_items rit
      join r on r.id = rit.return_id
      join public.sale_items sit on sit.id = rit.sale_item_id
     group by r.d
  )
  select jsonb_build_object(
    'today', jsonb_build_object(
      'sales', coalesce((select sum(total) from s where d = v_today), 0),
      'count', (select count(*) from s where d = v_today),
      'vat', coalesce((select sum(vat_amount) from s where d = v_today), 0)
             - coalesce((select sum(vat_amount) from r where d = v_today), 0),
      'returns', coalesce((select sum(total) from r where d = v_today), 0),
      'profit', coalesce((select profit from si where d = v_today), 0)
                - coalesce((select profit from ri where d = v_today), 0)
    ),
    'month', jsonb_build_object(
      'sales', coalesce((select sum(total) from s where d >= v_month), 0),
      'count', (select count(*) from s where d >= v_month),
      'returns', coalesce((select sum(total) from r where d >= v_month), 0),
      'profit', coalesce((select sum(profit) from si where d >= v_month), 0)
                - coalesce((select sum(profit) from ri where d >= v_month), 0)
    ),
    'daily', (
      select jsonb_agg(jsonb_build_object(
        'day', g.d,
        'total', coalesce((select sum(total) from s where s.d = g.d), 0)
                 - coalesce((select sum(total) from r where r.d = g.d), 0),
        'count', (select count(*) from s where s.d = g.d)
      ) order by g.d)
      from (select gs::date as d from generate_series(v_today - 13, v_today, interval '1 day') gs) as g
    ),
    'payments_today', coalesce((
      select jsonb_agg(jsonb_build_object('method', method, 'amount', amount))
        from (
          select p.method,
                 sum(p.amount) - case when p.method = 'cash'
                   then coalesce((select sum(change_amount) from s where d = v_today), 0) else 0 end as amount
            from public.sale_payments p join s on s.id = p.sale_id
           where s.d = v_today group by p.method
        ) x), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(t order by t.qty desc) from (
        select i.product_name as name, sum(i.qty - i.returned_qty) as qty, sum(i.line_total) as total
          from public.sale_items i join s on s.id = i.sale_id
         where s.d > v_today - 30
         group by i.product_name
         order by 2 desc limit 8
      ) t), '[]'::jsonb),
    'low_stock', coalesce((
      select jsonb_agg(t) from (
        select v.id, p.name, v.size, v.color, v.sku, v.stock_qty, v.low_stock_threshold
          from public.product_variants v join public.products p on p.id = v.product_id
         where v.is_active and p.is_active and v.stock_qty <= v.low_stock_threshold
         order by v.stock_qty asc limit 10
      ) t), '[]'::jsonb),
    'low_stock_count', (
      select count(*) from public.product_variants v join public.products p on p.id = v.product_id
       where v.is_active and p.is_active and v.stock_qty <= v.low_stock_threshold),
    'stock_value', (
      select jsonb_build_object(
        'cost', coalesce(sum(greatest(v.stock_qty, 0) * coalesce(c.cost_price, 0)), 0),
        'retail', coalesce(sum(greatest(v.stock_qty, 0) * coalesce(v.price, p.base_price)), 0),
        'units', coalesce(sum(greatest(v.stock_qty, 0)), 0))
        from public.product_variants v
        join public.products p on p.id = v.product_id
        left join public.variant_costs c on c.variant_id = v.id
       where v.is_active and p.is_active),
    'recent', coalesce((
      select jsonb_agg(t) from (
        select sa.id, sa.invoice_no, sa.total, sa.status, sa.created_at, pr.full_name as cashier
          from public.sales sa left join public.profiles pr on pr.id = sa.cashier_id
         order by sa.created_at desc limit 8
      ) t), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- تقرير المبيعات والأرباح لفترة
-- ---------------------------------------------------------------------
create or replace function public.sales_report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamp at time zone 'Asia/Riyadh';
  v_to timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Riyadh';
  v_result jsonb;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  with
  s as (select * from public.sales where created_at >= v_from and created_at < v_to),
  i as (select i.*, s.cashier_id from public.sale_items i join s on s.id = i.sale_id),
  r as (select * from public.returns where created_at >= v_from and created_at < v_to),
  ri as (
    select ri.*, si.unit_cost, si.product_name, r.cashier_id
      from public.return_items ri
      join r on r.id = ri.return_id
      join public.sale_items si on si.id = ri.sale_item_id
  ),
  summary as (
    select
      coalesce((select sum(total) from s), 0) as gross_sales,
      (select count(*) from s) as invoices,
      coalesce((select sum(discount_total) from s), 0) as discounts,
      coalesce((select sum(vat_amount) from s), 0) as sales_vat,
      coalesce((select sum(total) from r), 0) as returns_total,
      coalesce((select sum(vat_amount) from r), 0) as returns_vat,
      (select count(*) from r) as returns_count,
      coalesce((select sum(unit_cost * qty) from i), 0) as sales_cost,
      coalesce((select sum(unit_cost * qty) from ri), 0) as returns_cost,
      coalesce((select sum(qty) from i), 0) as items_sold,
      coalesce((select sum(qty) from ri), 0) as items_returned
  )
  select jsonb_build_object(
    'summary', (
      select jsonb_build_object(
        'gross_sales', gross_sales,
        'invoices', invoices,
        'discounts', discounts,
        'returns', returns_total,
        'returns_count', returns_count,
        'net_sales', gross_sales - returns_total,
        'vat', sales_vat - returns_vat,
        'net_excl_vat', (gross_sales - sales_vat) - (returns_total - returns_vat),
        'cost', sales_cost - returns_cost,
        'gross_profit', (gross_sales - sales_vat) - (returns_total - returns_vat) - (sales_cost - returns_cost),
        'margin', case when (gross_sales - sales_vat) - (returns_total - returns_vat) > 0
          then round((((gross_sales - sales_vat) - (returns_total - returns_vat) - (sales_cost - returns_cost))
               / ((gross_sales - sales_vat) - (returns_total - returns_vat))) * 100, 1)
          else 0 end,
        'avg_ticket', case when invoices > 0 then round(gross_sales / invoices, 2) else 0 end,
        'items_sold', items_sold - items_returned
      ) from summary),
    'by_day', coalesce((
      select jsonb_agg(t order by t.day) from (
        select d as day,
               coalesce(sum(sales), 0) as sales,
               coalesce(sum(returns), 0) as returns,
               coalesce(sum(invoices), 0) as invoices,
               coalesce(sum(profit), 0) as profit
          from (
            select (s.created_at at time zone 'Asia/Riyadh')::date as d, s.total as sales, 0 as returns, 1 as invoices,
                   (s.subtotal - (select coalesce(sum(unit_cost * qty), 0) from i where i.sale_id = s.id)) as profit
              from s
            union all
            select (r.created_at at time zone 'Asia/Riyadh')::date, 0, r.total, 0,
                   -((r.total - r.vat_amount) - (select coalesce(sum(unit_cost * qty), 0) from ri where ri.return_id = r.id))
              from r
          ) x group by d
      ) t), '[]'::jsonb),
    'by_payment', coalesce((
      select jsonb_agg(jsonb_build_object('method', method, 'amount', amount, 'count', cnt))
        from (
          select p.method,
                 sum(p.amount) - case when p.method = 'cash' then coalesce((select sum(change_amount) from s), 0) else 0 end as amount,
                 count(distinct p.sale_id) as cnt
            from public.sale_payments p join s on s.id = p.sale_id
           group by p.method
        ) x), '[]'::jsonb),
    'refunds_by_method', coalesce((
      select jsonb_agg(jsonb_build_object('method', refund_method, 'amount', amount, 'count', cnt))
        from (select refund_method, sum(total) as amount, count(*) as cnt from r group by refund_method) x
      ), '[]'::jsonb),
    'by_cashier', coalesce((
      select jsonb_agg(t order by t.sales desc) from (
        select pr.full_name as name, count(*) as invoices, sum(s.total) as sales
          from s left join public.profiles pr on pr.id = s.cashier_id
         group by pr.full_name
      ) t), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(t order by t.revenue desc) from (
        select i.product_name as name,
               sum(i.qty) as qty,
               sum(i.line_total) as revenue,
               sum(i.line_total - i.vat_amount - i.unit_cost * i.qty) as profit
          from i group by i.product_name
         order by 3 desc limit 15
      ) t), '[]'::jsonb),
    'by_category', coalesce((
      select jsonb_agg(t order by t.revenue desc) from (
        select coalesce(c.name, 'بدون تصنيف') as name, sum(i.qty) as qty, sum(i.line_total) as revenue,
               sum(i.line_total - i.vat_amount - i.unit_cost * i.qty) as profit
          from i
          join public.product_variants v on v.id = i.variant_id
          join public.products p on p.id = v.product_id
          left join public.categories c on c.id = p.category_id
         group by c.name
      ) t), '[]'::jsonb),
    'by_size', coalesce((
      select jsonb_agg(t order by t.qty desc) from (
        select coalesce(v.size, '-') as name, sum(i.qty) as qty, sum(i.line_total) as revenue
          from i join public.product_variants v on v.id = i.variant_id
         group by v.size
      ) t), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- ملخص العميل
-- ---------------------------------------------------------------------
create or replace function public.customer_stats(p_customer_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.is_staff() then jsonb_build_object(
    'invoices', count(*),
    'total_spent', coalesce(sum(total - returned_amount), 0),
    'last_visit', max(created_at)
  ) end
  from public.sales where customer_id = p_customer_id
$$;

-- صلاحيات التنفيذ
revoke execute on all functions in schema public from anon, public;
grant execute on function
  public.current_user_role(), public.has_role(public.user_role[]), public.is_staff(), public.is_manager(),
  public.complete_sale(jsonb, jsonb, uuid, numeric, text),
  public.get_sale_for_return(text),
  public.process_return(uuid, jsonb, public.refund_method, text),
  public.adjust_stock(uuid, integer, text),
  public.receive_purchase(uuid),
  public.next_po_no(),
  public.start_stock_count(uuid, text),
  public.apply_stock_count(uuid),
  public.dashboard_stats(),
  public.sales_report(date, date),
  public.customer_stats(uuid)
to authenticated;

-- =====================================================================
-- 0005_storage_limits.sql
-- =====================================================================
-- =====================================================================
-- حدود رفع صور المنتجات: 5MB كحد أقصى، صور فقط، وداخل مجلد products/
-- =====================================================================
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'product-images';

drop policy if exists "product images insert" on storage.objects;
drop policy if exists "product images update" on storage.objects;
drop policy if exists "product images delete" on storage.objects;

create policy "product images insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = 'products' and public.is_manager());
create policy "product images update" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = 'products' and public.is_manager());
create policy "product images delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = 'products' and public.is_manager());

-- =====================================================================
-- 0006_shifts.sql
-- =====================================================================
-- =====================================================================
-- الورديات وإغلاق الصندوق
--   • كل موظف يفتح وردية برصيد افتتاحي، وكل بيع/مرتجع يُربط بورديته المفتوحة تلقائياً
--   • حركات نقدية يدوية على الدرج (إيداع/سحب) بسبب إلزامي
--   • الإغلاق: الموظف يدخل النقد المعدود (دون رؤية المتوقع)، والنظام يحسب العجز/الزيادة
-- إضافة فقط: لا تغيير على دوال البيع والمرتجعات، والربط يتم عبر triggers
-- =====================================================================

create type public.shift_status as enum ('open', 'closed');
create type public.cash_movement_type as enum ('in', 'out');

alter table public.store_settings
  add column require_shift boolean not null default true;

create sequence public.shift_seq start 1;

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  shift_no text not null unique,
  cashier_id uuid not null references public.profiles (id),
  status public.shift_status not null default 'open',
  opening_cash numeric(12,2) not null check (opening_cash >= 0),
  opened_at timestamptz not null default now(),
  opening_notes text,
  -- لقطة الأرقام عند الإغلاق (تبقى ثابتة حتى لو تغيرت البيانات لاحقاً)
  closed_at timestamptz,
  closed_by uuid references public.profiles (id),
  counted_cash numeric(12,2) check (counted_cash is null or counted_cash >= 0),
  expected_cash numeric(12,2),
  cash_difference numeric(12,2),
  summary jsonb,
  closing_notes text
);
-- وردية مفتوحة واحدة فقط لكل موظف
create unique index shifts_one_open_per_cashier on public.shifts (cashier_id) where status = 'open';
create index shifts_opened_idx on public.shifts (opened_at desc);

create table public.shift_cash_movements (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts (id) on delete cascade,
  type public.cash_movement_type not null,
  amount numeric(12,2) not null check (amount > 0),
  reason text not null check (length(trim(reason)) > 0),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index shift_cash_movements_shift_idx on public.shift_cash_movements (shift_id);

alter table public.sales add column shift_id uuid references public.shifts (id);
alter table public.returns add column shift_id uuid references public.shifts (id);
create index sales_shift_idx on public.sales (shift_id);
create index returns_shift_idx on public.returns (shift_id);

-- ---------------------------------------------------------------------
-- ربط البيع/المرتجع بالوردية المفتوحة للموظف
-- ---------------------------------------------------------------------
create or replace function public.attach_open_shift()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_require boolean := (select require_shift from public.store_settings where id = 1);
begin
  select id into new.shift_id
    from public.shifts
   where cashier_id = new.cashier_id and status = 'open';

  if new.shift_id is null and v_require then
    if tg_table_name = 'sales' then
      raise exception 'لا توجد وردية مفتوحة — افتح الوردية أولاً';
    -- المرتجع بغير النقد لا يمس الدرج، فلا يحتاج وردية
    elsif (to_jsonb(new) ->> 'refund_method') = 'cash' then
      raise exception 'لا توجد وردية مفتوحة — افتح الوردية أولاً';
    end if;
  end if;
  return new;
end;
$$;

create trigger sales_attach_shift before insert on public.sales
  for each row execute function public.attach_open_shift();
create trigger returns_attach_shift before insert on public.returns
  for each row execute function public.attach_open_shift();

-- ---------------------------------------------------------------------
-- ملخص الوردية (محسوب لحظياً)
-- ---------------------------------------------------------------------
create or replace function public._shift_numbers(p_shift_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  with
  sh as (select * from public.shifts where id = p_shift_id),
  s as (select * from public.sales where shift_id = p_shift_id),
  pay as (
    select p.method, sum(p.amount) as amount
      from public.sale_payments p join s on s.id = p.sale_id
     group by p.method
  ),
  r as (select * from public.returns where shift_id = p_shift_id),
  mv as (
    select coalesce(sum(amount) filter (where type = 'in'), 0) as cash_in,
           coalesce(sum(amount) filter (where type = 'out'), 0) as cash_out
      from public.shift_cash_movements where shift_id = p_shift_id
  ),
  n as (
    select
      (select opening_cash from sh) as opening_cash,
      coalesce((select amount from pay where method = 'cash'), 0)
        - coalesce((select sum(change_amount) from s), 0) as cash_sales,
      coalesce((select amount from pay where method = 'card'), 0) as card_sales,
      coalesce((select amount from pay where method = 'transfer'), 0) as transfer_sales,
      coalesce((select amount from pay where method = 'exchange_credit'), 0) as exchange_credit,
      coalesce((select sum(total) from s), 0) as total_sales,
      (select count(*) from s) as sales_count,
      coalesce((select sum(total) from r where refund_method = 'cash'), 0) as cash_refunds,
      coalesce((select sum(total) from r where refund_method = 'card'), 0) as card_refunds,
      coalesce((select sum(total) from r where refund_method = 'transfer'), 0) as transfer_refunds,
      coalesce((select sum(total) from r where refund_method = 'exchange'), 0) as exchange_returns,
      (select count(*) from r) as returns_count,
      (select cash_in from mv) as cash_in,
      (select cash_out from mv) as cash_out
  )
  select jsonb_build_object(
    'opening_cash', opening_cash,
    'cash_sales', cash_sales,
    'card_sales', card_sales,
    'transfer_sales', transfer_sales,
    'exchange_credit', exchange_credit,
    'total_sales', total_sales,
    'sales_count', sales_count,
    'cash_refunds', cash_refunds,
    'card_refunds', card_refunds,
    'transfer_refunds', transfer_refunds,
    'exchange_returns', exchange_returns,
    'returns_count', returns_count,
    'cash_in', cash_in,
    'cash_out', cash_out,
    'expected_cash', opening_cash + cash_sales - cash_refunds + cash_in - cash_out
  ) from n
$$;
revoke all on function public._shift_numbers(uuid) from public, anon, authenticated;

-- الملخص لمن يحق له: المدير/المالك، أو صاحب الوردية بعد إغلاقها.
-- أثناء الوردية لا يرى الكاشير النقد المتوقع (عدّ أعمى عند الإغلاق).
create or replace function public.shift_summary(p_shift_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_shift public.shifts;
  v_numbers jsonb;
begin
  select * into v_shift from public.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'الوردية غير موجودة';
  end if;
  if not (public.is_manager() or (public.is_staff() and v_shift.cashier_id = auth.uid())) then
    raise exception 'غير مصرح';
  end if;

  v_numbers := coalesce(v_shift.summary, public._shift_numbers(p_shift_id));

  if v_shift.status = 'open' and not public.is_manager() then
    v_numbers := jsonb_build_object(
      'opening_cash', v_numbers -> 'opening_cash',
      'sales_count', v_numbers -> 'sales_count',
      'returns_count', v_numbers -> 'returns_count',
      'total_sales', v_numbers -> 'total_sales'
    );
  end if;

  return jsonb_build_object(
    'id', v_shift.id,
    'shift_no', v_shift.shift_no,
    'status', v_shift.status,
    'cashier_id', v_shift.cashier_id,
    'cashier_name', (select full_name from public.profiles where id = v_shift.cashier_id),
    'opened_at', v_shift.opened_at,
    'closed_at', v_shift.closed_at,
    'closed_by_name', (select full_name from public.profiles where id = v_shift.closed_by),
    'counted_cash', v_shift.counted_cash,
    'cash_difference', v_shift.cash_difference,
    'opening_notes', v_shift.opening_notes,
    'closing_notes', v_shift.closing_notes,
    'numbers', v_numbers,
    'movements', coalesce((
      select jsonb_agg(jsonb_build_object('type', type, 'amount', amount, 'reason', reason, 'created_at', created_at)
                       order by created_at)
        from public.shift_cash_movements where shift_id = p_shift_id), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- فتح / حركة نقدية / إغلاق
-- ---------------------------------------------------------------------
create or replace function public.open_shift(p_opening_cash numeric, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if p_opening_cash is null or p_opening_cash < 0 then
    raise exception 'الرصيد الافتتاحي غير صحيح';
  end if;
  if exists (select 1 from public.shifts where cashier_id = auth.uid() and status = 'open') then
    raise exception 'لديك وردية مفتوحة بالفعل';
  end if;

  insert into public.shifts (shift_no, cashier_id, opening_cash, opening_notes)
  values (
    'SH-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.shift_seq')::text, 5, '0'),
    auth.uid(), round(p_opening_cash, 2), nullif(trim(p_notes), '')
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.add_cash_movement(
  p_type public.cash_movement_type, p_amount numeric, p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_shift uuid;
  v_id uuid;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open';
  if v_shift is null then
    raise exception 'لا توجد وردية مفتوحة';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'المبلغ غير صحيح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;

  insert into public.shift_cash_movements (shift_id, type, amount, reason)
  values (v_shift, p_type, round(p_amount, 2), trim(p_reason))
  returning id into v_id;
  return v_id;
end;
$$;

-- الموظف يغلق ورديته، والمدير/المالك يستطيع إغلاق أي وردية (مثلاً نسيها الموظف)
create or replace function public.close_shift(p_shift_id uuid, p_counted_cash numeric, p_notes text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shift public.shifts;
  v_numbers jsonb;
  v_expected numeric;
begin
  select * into v_shift from public.shifts where id = p_shift_id for update;
  if v_shift.id is null then
    raise exception 'الوردية غير موجودة';
  end if;
  if not (public.is_manager() or (public.is_staff() and v_shift.cashier_id = auth.uid())) then
    raise exception 'غير مصرح';
  end if;
  if v_shift.status <> 'open' then
    raise exception 'الوردية مغلقة بالفعل';
  end if;
  if p_counted_cash is null or p_counted_cash < 0 then
    raise exception 'أدخل النقد المعدود في الدرج';
  end if;

  v_numbers := public._shift_numbers(p_shift_id);
  v_expected := (v_numbers ->> 'expected_cash')::numeric;

  update public.shifts
     set status = 'closed',
         closed_at = now(),
         closed_by = auth.uid(),
         counted_cash = round(p_counted_cash, 2),
         expected_cash = v_expected,
         cash_difference = round(p_counted_cash, 2) - v_expected,
         summary = v_numbers,
         closing_notes = nullif(trim(p_notes), '')
   where id = p_shift_id;

  return public.shift_summary(p_shift_id);
end;
$$;

-- ---------------------------------------------------------------------
-- RLS: قراءة فقط (الكتابة عبر الدوال)
-- ---------------------------------------------------------------------
alter table public.shifts enable row level security;
alter table public.shift_cash_movements enable row level security;

revoke all on public.shifts, public.shift_cash_movements from anon;
revoke insert, update, delete on public.shifts, public.shift_cash_movements from authenticated;
grant select on public.shifts, public.shift_cash_movements to authenticated;
-- المبالغ المتوقعة والفروقات لا تُقرأ مباشرة؛ الكاشير يراها عبر shift_summary بعد الإغلاق
revoke select on public.shifts from authenticated;
grant select (id, shift_no, cashier_id, status, opening_cash, opened_at, closed_at, closed_by, opening_notes)
  on public.shifts to authenticated;

create policy shifts_select on public.shifts for select to authenticated
  using (public.is_manager() or (public.is_staff() and cashier_id = auth.uid()));
create policy shift_movements_select on public.shift_cash_movements for select to authenticated
  using (exists (select 1 from public.shifts s where s.id = shift_id));

create trigger shifts_audit after insert or update or delete on public.shifts
  for each row execute function public.audit_trigger();
create trigger shift_cash_movements_audit after insert or update or delete on public.shift_cash_movements
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- قائمة الورديات مع الأرقام (المدير يرى الكل، الموظف ورديّاته فقط وبدون المتوقع للمفتوحة)
-- ---------------------------------------------------------------------
create or replace function public.list_shifts(p_from date default null, p_to date default null)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row order by (row ->> 'opened_at') desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', s.id,
      'shift_no', s.shift_no,
      'status', s.status,
      'cashier_name', p.full_name,
      'is_mine', s.cashier_id = auth.uid(),
      'opened_at', s.opened_at,
      'closed_at', s.closed_at,
      'opening_cash', s.opening_cash,
      'total_sales', coalesce((s.summary ->> 'total_sales')::numeric,
                              (select coalesce(sum(total), 0) from public.sales where shift_id = s.id)),
      'expected_cash', case when public.is_manager() or s.status = 'closed' then
                         coalesce(s.expected_cash, (public._shift_numbers(s.id) ->> 'expected_cash')::numeric) end,
      'counted_cash', s.counted_cash,
      'cash_difference', s.cash_difference
    ) as row
      from public.shifts s
      left join public.profiles p on p.id = s.cashier_id
     where public.is_staff()
       and (public.is_manager() or s.cashier_id = auth.uid())
       and (p_from is null or s.opened_at >= p_from::timestamp at time zone 'Asia/Riyadh')
       and (p_to is null or s.opened_at < (p_to + 1)::timestamp at time zone 'Asia/Riyadh')
     order by s.opened_at desc
     limit 200
  ) t
$$;

grant execute on function
  public.shift_summary(uuid),
  public.open_shift(numeric, text),
  public.add_cash_movement(public.cash_movement_type, numeric, text),
  public.close_shift(uuid, numeric, text),
  public.list_shifts(date, date)
to authenticated;

-- الدوال الجديدة تُمنح لـ PUBLIC افتراضياً في PostgreSQL — نقصرها على المستخدمين المسجلين
revoke execute on function
  public.attach_open_shift(),
  public.shift_summary(uuid),
  public.open_shift(numeric, text),
  public.add_cash_movement(public.cash_movement_type, numeric, text),
  public.close_shift(uuid, numeric, text),
  public.list_shifts(date, date)
from public, anon;

-- =====================================================================
-- 0007_expenses.sql
-- =====================================================================
-- =====================================================================
-- المصروفات وصافي الربح
--   • مصروفات مصنّفة بمبلغ شامل الضريبة + ضريبة مدخلات (إن وُجدت فاتورة ضريبية)
--   • الدفع من درج الوردية يُسجَّل تلقائياً كسحب في الوردية المفتوحة
--   • صورة الإيصال في مخزن خاص (غير عام) للمدير والمالك فقط
-- إضافة فقط: لا تغيير على الجداول والدوال السابقة
-- =====================================================================

create type public.expense_payment as enum ('cash_drawer', 'cash', 'card', 'transfer');

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

insert into public.expense_categories (name, sort_order) values
  ('إيجار', 1), ('رواتب', 2), ('كهرباء وماء', 3), ('اتصالات وإنترنت', 4), ('صيانة', 5),
  ('تسويق وإعلانات', 6), ('نقل وتوصيل', 7), ('مستلزمات المحل (أكياس، علاقات)', 8),
  ('رسوم حكومية', 9), ('أخرى', 10);

create sequence public.expense_seq start 1;

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  expense_no text not null unique
    default ('EXP-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.expense_seq')::text, 5, '0')),
  category_id uuid not null references public.expense_categories (id),
  expense_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  amount numeric(12,2) not null check (amount > 0),               -- المدفوع شامل الضريبة
  vat_amount numeric(12,2) not null default 0 check (vat_amount >= 0),
  payment_method public.expense_payment not null,
  payee text,
  reference text,                                                   -- رقم فاتورة المورد
  notes text,
  receipt_path text,                                                -- داخل مخزن expense-receipts
  shift_movement_id uuid references public.shift_cash_movements (id),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vat_le_amount check (vat_amount <= amount)
);
create index expenses_date_idx on public.expenses (expense_date desc);
create index expenses_category_idx on public.expenses (category_id);

create trigger expenses_touch before update on public.expenses
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- الدفع من الدرج: سحب تلقائي من الوردية المفتوحة للمستخدم
-- ---------------------------------------------------------------------
create or replace function public.expense_drawer_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_shift uuid;
  v_shift_status public.shift_status;
  v_category text;
begin
  if tg_op = 'INSERT' then
    if new.payment_method = 'cash_drawer' then
      select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open';
      if v_shift is null then
        raise exception 'لا توجد لديك وردية مفتوحة للدفع من الدرج — افتح وردية أو اختر طريقة دفع أخرى';
      end if;
      select name into v_category from public.expense_categories where id = new.category_id;
      insert into public.shift_cash_movements (shift_id, type, amount, reason)
      values (v_shift, 'out', new.amount,
              'مصروف ' || new.expense_no || ': ' || coalesce(v_category, '') || coalesce(' — ' || nullif(trim(new.payee), ''), ''))
      returning id into new.shift_movement_id;
    else
      new.shift_movement_id := null;
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    -- لا يُسمح بتغيير ارتباط الدرج أو المبلغ لمصروف مدفوع من الدرج (تقرير الوردية يعتمد عليه)
    if (old.payment_method = 'cash_drawer' or new.payment_method = 'cash_drawer')
       and (new.payment_method is distinct from old.payment_method or new.amount is distinct from old.amount) then
      raise exception 'لا يمكن تعديل مبلغ أو طريقة دفع مصروف مدفوع من الدرج — احذفه وأعد إدخاله';
    end if;
    new.shift_movement_id := old.shift_movement_id;
    new.expense_no := old.expense_no;
    new.created_by := old.created_by;
    return new;
  end if;

  -- DELETE
  if old.shift_movement_id is not null then
    select s.status into v_shift_status
      from public.shift_cash_movements m join public.shifts s on s.id = m.shift_id
     where m.id = old.shift_movement_id;
    if v_shift_status = 'closed' then
      raise exception 'لا يمكن حذف مصروف مدفوع من درج وردية مغلقة';
    end if;
  end if;
  return old;
end;
$$;

create trigger expenses_drawer_before before insert or update or delete on public.expenses
  for each row execute function public.expense_drawer_guard();

-- بعد حذف المصروف: حذف حركة الدرج المرتبطة (الوردية ما زالت مفتوحة — تحقق منه قبل الحذف)
create or replace function public.expense_drawer_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.shift_movement_id is not null then
    delete from public.shift_cash_movements where id = old.shift_movement_id;
  end if;
  return old;
end;
$$;

create trigger expenses_drawer_after_delete after delete on public.expenses
  for each row execute function public.expense_drawer_cleanup();

-- ---------------------------------------------------------------------
-- RLS: المدير والمالك فقط
-- ---------------------------------------------------------------------
alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;

revoke all on public.expense_categories, public.expenses from anon;
grant select, insert, update, delete on public.expense_categories, public.expenses to authenticated;
revoke usage on sequence public.expense_seq from anon;
grant usage on sequence public.expense_seq to authenticated;

create policy expense_categories_all on public.expense_categories for all to authenticated
  using (public.is_manager()) with check (public.is_manager());
create policy expenses_all on public.expenses for all to authenticated
  using (public.is_manager()) with check (public.is_manager());

create trigger expense_categories_audit after insert or update or delete on public.expense_categories
  for each row execute function public.audit_trigger();
create trigger expenses_audit after insert or update or delete on public.expenses
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- ملخص المصروفات لفترة (للتقارير ولوحة التحكم)
-- ---------------------------------------------------------------------
create or replace function public.expenses_summary(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return (
    with e as (
      select * from public.expenses where expense_date between p_from and p_to
    )
    select jsonb_build_object(
      'total', coalesce((select sum(amount) from e), 0),
      'vat', coalesce((select sum(vat_amount) from e), 0),
      'net', coalesce((select sum(amount - vat_amount) from e), 0),
      'count', (select count(*) from e),
      'from_drawer', coalesce((select sum(amount) from e where payment_method = 'cash_drawer'), 0),
      'by_category', coalesce((
        select jsonb_agg(t order by t.total desc) from (
          select c.name, sum(e.amount) as total, sum(e.amount - e.vat_amount) as net, count(*) as count
            from e join public.expense_categories c on c.id = e.category_id
           group by c.name
        ) t), '[]'::jsonb)
    )
  );
end;
$$;

revoke execute on function public.expenses_summary(date, date) from public, anon;
revoke execute on function public.expense_drawer_guard(), public.expense_drawer_cleanup() from public, anon;
grant execute on function public.expenses_summary(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- صور الإيصالات: مخزن خاص (روابط موقّعة مؤقتة)، للمدير والمالك فقط، داخل مجلد expenses/
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-receipts', 'expense-receipts', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create policy "expense receipts read" on storage.objects for select to authenticated
  using (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());
create policy "expense receipts insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());
create policy "expense receipts update" on storage.objects for update to authenticated
  using (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());
create policy "expense receipts delete" on storage.objects for delete to authenticated
  using (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());

-- =====================================================================
-- 0008_purchase_advisor.sql
-- =====================================================================
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

-- =====================================================================
-- 0013_locations_transfers.sql
-- =====================================================================
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

-- =====================================================================
-- 0014_smart_counts.sql
-- =====================================================================
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
  v_scan bigint;
  v_code text := trim(coalesce(p_code, ''));
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  -- قفل مشترك: المسحات المتزامنة تمر معاً، أما الإرسال/الاعتماد (FOR UPDATE) فينتظرها
  select * into c from public.stock_counts where id = p_count_id for share;
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

  if coalesce(p_qty, 0) = 0 then
    raise exception 'كمية غير صحيحة';
  end if;

  -- المسحة تحجز مرجعها أولاً: نفس المسحة (ضغط مزدوج/إعادة إرسال، ولو من جلستين متزامنتين) لا تُحسب مرتين
  insert into public.stock_count_scans (count_id, variant_id, qty, client_ref)
  values (p_count_id, v_variant.id, p_qty, p_client_ref)
  on conflict (client_ref) do nothing
  returning id into v_scan;
  if v_scan is null then
    select * into v_item from public.stock_count_items where count_id = p_count_id and variant_id = v_variant.id;
    return jsonb_build_object('variant_id', v_variant.id, 'sku', v_variant.sku, 'name', v_variant.name,
                              'label', v_variant.label, 'counted', v_item.counted_qty, 'duplicate', true);
  end if;

  insert into public.stock_count_items (count_id, variant_id, expected_qty)
  values (p_count_id, v_variant.id,
          case when c.location_id is null then (select stock_qty from public.product_variants where id = v_variant.id)
               else public._location_qty_at(c.location_id, v_variant.id, c.snapshot_at) end)
  on conflict (count_id, variant_id) do nothing;

  -- التحديث يقفل الصف: مسحات متزامنة لنفس الصنف تُجمع بالترتيب
  perform set_config('app.count_rpc', 'on', true);
  update public.stock_count_items
     set counted_qty = coalesce(counted_qty, 0) + p_qty, counted_by = auth.uid(), counted_at = clock_timestamp()
   where count_id = p_count_id and variant_id = v_variant.id
  returning * into v_item;
  if v_item.counted_qty < 0 then
    raise exception 'الكمية المعدودة لا تكون سالبة';
  end if;
  perform set_config('app.count_rpc', '', true);

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
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if (select status from public.stock_counts where id = p_count_id) is distinct from 'open' then
    raise exception 'الجرد غير مفتوح';
  end if;
  if p_qty is null or p_qty < 0 then
    raise exception 'كمية غير صحيحة';
  end if;
  select coalesce(counted_qty, 0) into v_current from public.stock_count_items
   where count_id = p_count_id and variant_id = p_variant for update;
  if p_qty = coalesce(v_current, 0) then
    perform set_config('app.count_rpc', 'on', true);
    update public.stock_count_items set counted_qty = p_qty, counted_by = auth.uid(), counted_at = clock_timestamp()
     where count_id = p_count_id and variant_id = p_variant and counted_qty is null;
    perform set_config('app.count_rpc', '', true);
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

-- جرد أعمى: الكمية النظامية لا تُقرأ مباشرة (المدير يراها عبر count_review)
revoke select on public.stock_count_items from authenticated;
grant select (id, count_id, variant_id, counted_qty, counted_by, counted_at) on public.stock_count_items to authenticated;

-- جرد الموقع يُعدّ عبر المسحات فقط (سجل كامل ومنع التكرار). الجرد القديم (بلا موقع) يبقى كما كان
create or replace function public.guard_count_item_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.counted_qty is distinct from old.counted_qty
     and coalesce(current_setting('app.count_rpc', true), '') <> 'on'
     and (select location_id from public.stock_counts where id = new.count_id) is not null then
    raise exception 'جرد الموقع يُسجَّل بالمسح أو إدخال الكمية فقط';
  end if;
  return new;
end;
$$;
create trigger stock_count_items_guard before update on public.stock_count_items
  for each row execute function public.guard_count_item_update();

alter table public.stock_count_scans enable row level security;
revoke all on public.stock_count_scans from anon;
revoke insert, update, delete on public.stock_count_scans from authenticated;
grant select on public.stock_count_scans to authenticated;
create policy count_scans_select on public.stock_count_scans for select to authenticated using (public.is_staff());

revoke all on function public._location_qty_at(uuid, uuid, timestamptz), public.guard_legacy_count(),
  public.guard_legacy_apply(), public.guard_count_item_update() from public, anon, authenticated;
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

-- =====================================================================
-- 0015_inventory_intelligence.sql
-- =====================================================================
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

-- مطلوب من المورد ولم يصل (مسودة أو مرسل) — نفس تعريف مساعد الشراء، لموقع الاستلام.
-- دالة مستقلة حتى تستبدلها ترقية المشتريات (الاستلام الجزئي) دون إعادة تعريف دوال التوفر
create or replace function public._open_po_qty()
returns table (loc uuid, variant_id uuid, qty integer)
language sql stable security definer set search_path = public as $$
  select coalesce(po.location_id, public._default_location()), pi.variant_id, sum(pi.qty)::integer
    from public.purchase_items pi join public.purchase_orders po on po.id = pi.purchase_id
   where po.status in ('draft', 'ordered') group by 1, 2
$$;

-- لكل موقع (متجر/مستودع) وصنف: الكميات الخمس + المبيعات + التكلفة والسعر
create or replace function public.location_availability(p_location uuid default null)
returns table (
  location_id uuid, location_name text, location_kind public.location_kind,
  variant_id uuid, product_id uuid, product_name text, category_id uuid, sku text, barcode text,
  size text, color text, on_hand integer, reserved integer, outgoing integer, available integer, in_transit integer,
  incoming_approved integer, n7 integer, n30 integer, n60 integer, n90 integer, last_sale_at timestamptz,
  unit_cost numeric, unit_price numeric, age_days integer, on_order integer
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
  open_po as (select * from public._open_po_qty()),
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
           coalesce(sa.first_sale_at, 'infinity'::timestamptz))) / 86400), 1)::integer,
         coalesce(po.qty, 0)
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
    left join open_po po on po.loc = l.id and po.variant_id = v.id
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

revoke all on function public._reserved_map(), public._location_sales(), public._open_po_qty() from public, anon, authenticated;
revoke execute on function
  public.location_availability(uuid), public.pos_location_context(), public.variant_locations(uuid),
  public.size_color_gaps(uuid), public.inventory_anomalies(), public.dead_stock_plan(uuid)
from public, anon;
grant execute on function
  public.location_availability(uuid), public.pos_location_context(), public.variant_locations(uuid),
  public.size_color_gaps(uuid), public.inventory_anomalies(), public.dead_stock_plan(uuid)
to authenticated;

-- =====================================================================
-- 0016_decision_center.sql
-- =====================================================================
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
  -- القادم = بالطريق + تحويل معتمد + مطلوب من المورد ولم يصل: لا يُقترح شراء أو نقل ما هو قادم أصلاً
  update _dc set need = case when location_kind = 'store' and avg_d > 0 and available + in_transit + incoming_approved + on_order <= rop
                             then greatest(target - (available + in_transit + incoming_approved + on_order), 0) else 0 end;
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
                                   'in_transit', r.in_transit + r.incoming_approved, 'on_order', r.on_order, 'sold_7', r.n7, 'sold_30', r.n30, 'sold_60', r.n60,
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
               r.location_name, r.avg_d, r.n30, r.available, r.in_transit + r.incoming_approved + r.on_order, r.rop, r.need,
               case when v_moved > 0 then format('يُغطّى %s بالنقل (%s)، والمتبقي بلا فائض في المواقع الأخرى ←',
                                                  v_moved, array_to_string(v_parts, '، '))
                    when v_elsewhere > 0 then format('متوفر %s في مواقع أخرى لكنها تحتاجه لمبيعاتها ←', v_elsewhere)
                    else 'لا يوجد في أي موقع آخر ←' end,
               v_remaining),
        jsonb_build_object('to', jsonb_build_object('name', r.location_name, 'on_hand', r.on_hand, 'available', r.available,
                                                    'in_transit', r.in_transit + r.incoming_approved, 'on_order', r.on_order, 'sold_30', r.n30, 'sold_90', r.n90,
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

commit;
