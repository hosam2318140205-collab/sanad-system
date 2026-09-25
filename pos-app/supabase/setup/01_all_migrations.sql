-- ملف مُولَّد تلقائياً من supabase/migrations — لا تعدّله يدوياً (npm run db:bundle)
-- نفّذه مرة واحدة فقط على مشروع Supabase جديد، في SQL Editor.
-- يحتوي: 0001_schema.sql, 0002_triggers_audit.sql, 0003_rls.sql, 0004_functions.sql, 0005_storage_limits.sql, 0006_shifts.sql, 0007_expenses.sql

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

commit;
