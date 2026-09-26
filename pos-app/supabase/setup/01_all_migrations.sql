-- ملف مُولَّد تلقائياً من supabase/migrations — لا تعدّله يدوياً (npm run db:bundle)
-- نفّذه مرة واحدة فقط على مشروع Supabase جديد، في SQL Editor.
-- يحتوي: 0001_schema.sql, 0002_triggers_audit.sql, 0003_rls.sql, 0004_functions.sql, 0005_storage_limits.sql, 0006_shifts.sql, 0007_expenses.sql, 0008_purchase_advisor.sql, 0009_customer_accounts.sql, 0010_promotions_reservations.sql, 0011_sales_v2.sql, 0012_customer_insights.sql

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
-- 0009_customer_accounts.sql
-- =====================================================================
-- =====================================================================
-- Sales & Customers 2.0 — (1) حسابات العملاء: الآجل، التحصيلات، كشف الحساب، نقاط الولاء
--   • دفتر أستاذ للذمم (customer_ledger) ودفتر للنقاط (loyalty_ledger): إلحاق فقط، ولكل قيد مصدر فريد
--     (نوع القيد + رقم المستند) فلا يمكن ترحيل نفس المستند مرتين
--   • الأرصدة المجمّعة في customer_accounts تُحدَّث فقط داخل دوال الترحيل
--   • التحصيل النقدي من الدرج يُسجَّل تلقائياً كإيداع في وردية الموظف (مثل المصروفات)
-- إضافة فقط: لا تغيير على جداول أو دوال سابقة
-- =====================================================================

-- طرق جديدة: البيع الآجل، والإرجاع إلى حساب العميل (تُستخدم في 0011)
alter type public.payment_method add value if not exists 'on_account';
alter type public.refund_method add value if not exists 'account';

create type public.ar_entry_type as enum ('sale', 'return', 'receipt', 'refund', 'void', 'adjust');
create type public.loyalty_entry_type as enum ('earn', 'redeem', 'return_reverse', 'return_restore', 'adjust');
create type public.collection_method as enum ('cash_drawer', 'cash', 'card', 'transfer');
create type public.collection_kind as enum ('receipt', 'refund');

alter table public.store_settings
  add column loyalty_enabled boolean not null default false,
  add column loyalty_points_per_sar numeric(8,4) not null default 0.1
    check (loyalty_points_per_sar >= 0 and loyalty_points_per_sar <= 100),
  add column loyalty_point_value numeric(8,4) not null default 0.1
    check (loyalty_point_value >= 0 and loyalty_point_value <= 100),
  add column loyalty_min_redeem integer not null default 50 check (loyalty_min_redeem >= 1),
  add column loyalty_max_redeem_pct numeric(5,2) not null default 50
    check (loyalty_max_redeem_pct > 0 and loyalty_max_redeem_pct <= 100),
  add column allow_cashier_credit boolean not null default false,
  add column reservation_days integer not null default 3 check (reservation_days between 1 and 60);

-- ---------------------------------------------------------------------
-- الأرصدة (لكل عميل صف واحد، يُنشأ عند أول حركة أو عند تحديد حد الائتمان)
--   account_balance > 0 : على العميل للمتجر      < 0 : رصيد دائن للعميل (عربون/مرتجع إلى الحساب)
--   credit_limit null   : البيع الآجل غير مسموح لهذا العميل
-- ---------------------------------------------------------------------
create table public.customer_accounts (
  customer_id uuid primary key references public.customers (id) on delete restrict,
  credit_limit numeric(12,2) check (credit_limit is null or credit_limit >= 0),
  account_balance numeric(12,2) not null default 0,
  loyalty_points integer not null default 0,
  updated_at timestamptz not null default now()
);

create table public.customer_ledger (
  id bigint generated always as identity primary key,
  customer_id uuid not null references public.customers (id) on delete restrict,
  entry_type public.ar_entry_type not null,
  source_id uuid not null,
  ref_no text,
  debit numeric(12,2) not null default 0 check (debit >= 0),
  credit numeric(12,2) not null default 0 check (credit >= 0),
  balance_after numeric(12,2) not null,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  constraint ledger_one_side check ((debit > 0) <> (credit > 0)),
  -- منع الترحيل المزدوج لنفس المستند
  constraint ledger_unique_source unique (entry_type, source_id)
);
create index customer_ledger_customer_idx on public.customer_ledger (customer_id, created_at, id);

create table public.loyalty_ledger (
  id bigint generated always as identity primary key,
  customer_id uuid not null references public.customers (id) on delete restrict,
  entry_type public.loyalty_entry_type not null,
  source_id uuid not null,
  ref_no text,
  points integer not null check (points <> 0),
  balance_after integer not null,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  constraint loyalty_unique_source unique (entry_type, source_id)
);
create index loyalty_ledger_customer_idx on public.loyalty_ledger (customer_id, created_at, id);

create sequence public.collection_seq start 1;

create table public.customer_payments (
  id uuid primary key default gen_random_uuid(),
  receipt_no text not null unique
    default ('RCP-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.collection_seq')::text, 5, '0')),
  customer_id uuid not null references public.customers (id) on delete restrict,
  kind public.collection_kind not null default 'receipt',
  amount numeric(12,2) not null check (amount > 0),
  method public.collection_method not null,
  reference text,
  notes text,
  reservation_id uuid,                                   -- عربون حجز (المفتاح يُضاف في 0010)
  shift_movement_id uuid references public.shift_cash_movements (id),
  client_ref uuid unique,                                -- مفتاح منع التكرار من الواجهة
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references public.profiles (id),
  void_reason text
);
create index customer_payments_customer_idx on public.customer_payments (customer_id, created_at desc);

-- ---------------------------------------------------------------------
-- الترحيل (داخلي — تستدعيه الدوال فقط)
-- ---------------------------------------------------------------------
create or replace function public._customer_account(p_customer_id uuid)
returns public.customer_accounts
language plpgsql security definer set search_path = public as $$
declare
  v public.customer_accounts;
begin
  insert into public.customer_accounts (customer_id) values (p_customer_id) on conflict do nothing;
  select * into v from public.customer_accounts where customer_id = p_customer_id for update;
  return v;
end;
$$;

create or replace function public._post_ar(
  p_customer_id uuid, p_type public.ar_entry_type, p_source_id uuid, p_ref_no text,
  p_debit numeric, p_credit numeric, p_note text default null
) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_balance numeric;
begin
  if coalesce(p_debit, 0) = 0 and coalesce(p_credit, 0) = 0 then
    return null;
  end if;
  perform public._customer_account(p_customer_id);
  update public.customer_accounts
     set account_balance = account_balance + coalesce(p_debit, 0) - coalesce(p_credit, 0), updated_at = now()
   where customer_id = p_customer_id
  returning account_balance into v_balance;

  insert into public.customer_ledger (customer_id, entry_type, source_id, ref_no, debit, credit, balance_after, note)
  values (p_customer_id, p_type, p_source_id, p_ref_no, coalesce(p_debit, 0), coalesce(p_credit, 0), v_balance, p_note);
  return v_balance;
end;
$$;

create or replace function public._post_loyalty(
  p_customer_id uuid, p_type public.loyalty_entry_type, p_source_id uuid, p_ref_no text,
  p_points integer, p_note text default null
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_balance integer;
begin
  if coalesce(p_points, 0) = 0 then
    return null;
  end if;
  perform public._customer_account(p_customer_id);
  update public.customer_accounts
     set loyalty_points = loyalty_points + p_points, updated_at = now()
   where customer_id = p_customer_id
  returning loyalty_points into v_balance;

  insert into public.loyalty_ledger (customer_id, entry_type, source_id, ref_no, points, balance_after, note)
  values (p_customer_id, p_type, p_source_id, p_ref_no, p_points, v_balance, p_note);
  return v_balance;
end;
$$;

revoke all on function public._customer_account(uuid) from public, anon, authenticated;
revoke all on function public._post_ar(uuid, public.ar_entry_type, uuid, text, numeric, numeric, text) from public, anon, authenticated;
revoke all on function public._post_loyalty(uuid, public.loyalty_entry_type, uuid, text, integer, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- التحصيل من العميل / رد رصيد دائن للعميل
--   p_kind = 'receipt' : العميل يدفع (يُنقص ما عليه، أو يُنشئ رصيداً دائناً كعربون)
--   p_kind = 'refund'  : المتجر يرد للعميل رصيده الدائن (للمدير فقط، ولا يتجاوز الرصيد الدائن)
--   الكاشير: من الدرج أو شبكة أو تحويل فقط. «نقداً خارج الدرج» للمدير/المالك.
-- ---------------------------------------------------------------------
create or replace function public.record_customer_payment(
  p_customer_id uuid,
  p_amount numeric,
  p_method public.collection_method,
  p_kind public.collection_kind default 'receipt',
  p_reference text default null,
  p_notes text default null,
  p_client_ref uuid default null,
  p_reservation_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  v_existing public.customer_payments;
  v_acc public.customer_accounts;
  v_customer public.customers;
  v_amount numeric := round(p_amount, 2);
  v_shift uuid;
  v_movement uuid;
  v_id uuid;
  v_no text;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;

  -- نفس الطلب أُرسل مرتين (انقطاع شبكة/ضغط مزدوج): نعيد نفس السند دون ترحيل جديد
  if p_client_ref is not null then
    select * into v_existing from public.customer_payments where client_ref = p_client_ref;
    if v_existing.id is not null then
      if v_existing.created_by is distinct from auth.uid() or v_existing.customer_id <> p_customer_id then
        raise exception 'مرجع العملية مستخدم مسبقاً';
      end if;
      return v_existing.id;
    end if;
  end if;

  select * into v_customer from public.customers where id = p_customer_id;
  if v_customer.id is null then
    raise exception 'العميل غير موجود';
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'المبلغ غير صحيح';
  end if;
  if p_kind = 'refund' and v_role = 'cashier' then
    raise exception 'رد الرصيد للعميل للمدير فقط';
  end if;
  if p_method = 'cash' and v_role = 'cashier' then
    raise exception 'الكاشير يحصّل نقداً عبر الدرج فقط';
  end if;

  v_acc := public._customer_account(p_customer_id);   -- قفل حساب العميل حتى نهاية العملية
  if p_kind = 'refund' and v_amount > -v_acc.account_balance + 0.001 then
    raise exception 'لا يوجد رصيد دائن كافٍ للعميل (الرصيد الدائن %)', greatest(-v_acc.account_balance, 0);
  end if;

  insert into public.customer_payments (customer_id, kind, amount, method, reference, notes, client_ref, reservation_id)
  values (p_customer_id, p_kind, v_amount, p_method, nullif(trim(p_reference), ''), nullif(trim(p_notes), ''),
          p_client_ref, p_reservation_id)
  returning id, receipt_no into v_id, v_no;

  if p_method = 'cash_drawer' then
    select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open';
    if v_shift is null then
      raise exception 'لا توجد لديك وردية مفتوحة — افتح وردية أو اختر طريقة أخرى';
    end if;
    insert into public.shift_cash_movements (shift_id, type, amount, reason)
    values (v_shift, case when p_kind = 'receipt' then 'in' else 'out' end::public.cash_movement_type, v_amount,
            case when p_kind = 'receipt' then 'تحصيل ' else 'رد رصيد ' end || v_no || ': ' || v_customer.name)
    returning id into v_movement;
    update public.customer_payments set shift_movement_id = v_movement where id = v_id;
  end if;

  if p_kind = 'receipt' then
    perform public._post_ar(p_customer_id, 'receipt', v_id, v_no, 0, v_amount, nullif(trim(p_notes), ''));
  else
    perform public._post_ar(p_customer_id, 'refund', v_id, v_no, v_amount, 0, nullif(trim(p_notes), ''));
  end if;
  return v_id;
end;
$$;

-- إلغاء سند (للمدير): قيد عكسي في الدفتر + حركة درج عكسية، والسند يبقى ظاهراً كملغي
create or replace function public.void_customer_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v public.customer_payments;
  v_shift public.shifts;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'سبب الإلغاء مطلوب';
  end if;
  select * into v from public.customer_payments where id = p_payment_id for update;
  if v.id is null then
    raise exception 'السند غير موجود';
  end if;
  if v.voided_at is not null then
    raise exception 'السند ملغي مسبقاً';
  end if;

  if v.shift_movement_id is not null then
    select s.* into v_shift from public.shift_cash_movements m join public.shifts s on s.id = m.shift_id
     where m.id = v.shift_movement_id;
    if v_shift.status = 'closed' then
      raise exception 'لا يمكن إلغاء سند نقدي من درج وردية مغلقة';
    end if;
    insert into public.shift_cash_movements (shift_id, type, amount, reason)
    values (v_shift.id, case when v.kind = 'receipt' then 'out' else 'in' end::public.cash_movement_type, v.amount,
            'إلغاء ' || v.receipt_no || ': ' || trim(p_reason));
  end if;

  perform public._customer_account(v.customer_id);
  if v.kind = 'receipt' then
    perform public._post_ar(v.customer_id, 'void', v.id, v.receipt_no, v.amount, 0, 'إلغاء: ' || trim(p_reason));
  else
    perform public._post_ar(v.customer_id, 'void', v.id, v.receipt_no, 0, v.amount, 'إلغاء: ' || trim(p_reason));
  end if;

  update public.customer_payments
     set voided_at = now(), voided_by = auth.uid(), void_reason = trim(p_reason)
   where id = v.id;
end;
$$;

-- حد الائتمان (null = لا يُسمح بالبيع الآجل)
create or replace function public.set_credit_limit(p_customer_id uuid, p_limit numeric)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_old numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_limit is not null and p_limit < 0 then
    raise exception 'حد الائتمان غير صحيح';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'العميل غير موجود';
  end if;
  select credit_limit into v_old from public._customer_account(p_customer_id);
  update public.customer_accounts set credit_limit = round(p_limit, 2), updated_at = now()
   where customer_id = p_customer_id;
  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed_fields)
  values ('customer_accounts', p_customer_id::text, 'UPDATE',
          jsonb_build_object('credit_limit', v_old), jsonb_build_object('credit_limit', round(p_limit, 2)),
          array['credit_limit']);
end;
$$;

-- تعديل يدوي للنقاط (للمدير) بسبب إلزامي
create or replace function public.adjust_loyalty(p_customer_id uuid, p_points integer, p_reason text)
returns integer
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(p_points, 0) = 0 or coalesce(trim(p_reason), '') = '' then
    raise exception 'أدخل عدد النقاط والسبب';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'العميل غير موجود';
  end if;
  return public._post_loyalty(p_customer_id, 'adjust', gen_random_uuid(), null, p_points, trim(p_reason));
end;
$$;

-- ---------------------------------------------------------------------
-- كشف حساب العميل لفترة: رصيد أول المدة + الحركات برصيد تراكمي + رصيد آخر المدة
-- ---------------------------------------------------------------------
create or replace function public.customer_statement(p_customer_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_opening numeric;
  v_customer public.customers;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select * into v_customer from public.customers where id = p_customer_id;
  if v_customer.id is null then
    raise exception 'العميل غير موجود';
  end if;
  v_from := coalesce(p_from, '2000-01-01'::date)::timestamp at time zone 'Asia/Riyadh';
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Riyadh')::date) + 1)::timestamp at time zone 'Asia/Riyadh';

  select coalesce(sum(debit - credit), 0) into v_opening
    from public.customer_ledger where customer_id = p_customer_id and created_at < v_from;

  return jsonb_build_object(
    'customer', jsonb_build_object('id', v_customer.id, 'name', v_customer.name, 'phone', v_customer.phone,
                                   'vat_number', v_customer.vat_number),
    'credit_limit', (select credit_limit from public.customer_accounts where customer_id = p_customer_id),
    'from', p_from,
    'to', coalesce(p_to, (now() at time zone 'Asia/Riyadh')::date),
    'opening_balance', v_opening,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'date', x.created_at, 'type', x.entry_type, 'ref_no', x.ref_no, 'source_id', x.source_id,
               'debit', x.debit, 'credit', x.credit, 'note', x.note, 'balance', x.balance)
             order by x.created_at, x.id)
        from (
          select e.*, v_opening + sum(e.debit - e.credit) over (order by e.created_at, e.id) as balance
            from public.customer_ledger e
           where e.customer_id = p_customer_id and e.created_at >= v_from and e.created_at < v_to) x), '[]'::jsonb),
    'total_debit', (select coalesce(sum(debit), 0) from public.customer_ledger
                     where customer_id = p_customer_id and created_at >= v_from and created_at < v_to),
    'total_credit', (select coalesce(sum(credit), 0) from public.customer_ledger
                      where customer_id = p_customer_id and created_at >= v_from and created_at < v_to),
    'closing_balance', v_opening + (select coalesce(sum(debit - credit), 0) from public.customer_ledger
                                     where customer_id = p_customer_id and created_at >= v_from and created_at < v_to)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- الذمم المدينة وأعمارها (للمدير)
--   الأعمار بطريقة FIFO: المبلغ المستحق يُنسب لأحدث فواتير الآجل، والتحصيل يسدد الأقدم أولاً
-- ---------------------------------------------------------------------
create or replace function public.receivables_report()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return (
    with bal as (
      select a.customer_id, a.account_balance, a.credit_limit
        from public.customer_accounts a where a.account_balance <> 0
    ),
    debits as (
      select l.customer_id, l.debit, l.created_at,
             sum(l.debit) over (partition by l.customer_id order by l.created_at desc, l.id desc) as cum
        from public.customer_ledger l
        join bal b on b.customer_id = l.customer_id and b.account_balance > 0
       where l.debit > 0
    ),
    open_parts as (
      select d.customer_id, d.created_at,
             least(d.debit, greatest(b.account_balance - (d.cum - d.debit), 0)) as open_amount
        from debits d join bal b on b.customer_id = d.customer_id
    ),
    aging as (
      select customer_id,
             sum(open_amount) filter (where now() - created_at <= interval '30 days') as d0_30,
             sum(open_amount) filter (where now() - created_at > interval '30 days' and now() - created_at <= interval '60 days') as d31_60,
             sum(open_amount) filter (where now() - created_at > interval '60 days' and now() - created_at <= interval '90 days') as d61_90,
             sum(open_amount) filter (where now() - created_at > interval '90 days') as d90_plus
        from open_parts group by customer_id
    ),
    rows as (
      select c.id, c.name, c.phone, b.account_balance as balance, b.credit_limit,
             coalesce(a.d0_30, 0) as d0_30, coalesce(a.d31_60, 0) as d31_60,
             coalesce(a.d61_90, 0) as d61_90, coalesce(a.d90_plus, 0) as d90_plus,
             (select max(created_at) from public.customer_payments p
               where p.customer_id = c.id and p.kind = 'receipt' and p.voided_at is null) as last_payment_at
        from bal b join public.customers c on c.id = b.customer_id
         left join aging a on a.customer_id = b.customer_id
    )
    select jsonb_build_object(
      'total_receivable', coalesce((select sum(balance) from rows where balance > 0), 0),
      'total_credit_balances', coalesce((select -sum(balance) from rows where balance < 0), 0),
      'd0_30', coalesce((select sum(d0_30) from rows), 0),
      'd31_60', coalesce((select sum(d31_60) from rows), 0),
      'd61_90', coalesce((select sum(d61_90) from rows), 0),
      'd90_plus', coalesce((select sum(d90_plus) from rows), 0),
      'customers', coalesce((select jsonb_agg(to_jsonb(r) order by r.balance desc) from rows r), '[]'::jsonb)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- RLS: الموظفون يقرؤون (الكاشير يحتاج الرصيد والنقاط عند البيع)، والكتابة عبر الدوال فقط
-- ---------------------------------------------------------------------
alter table public.customer_accounts enable row level security;
alter table public.customer_ledger enable row level security;
alter table public.loyalty_ledger enable row level security;
alter table public.customer_payments enable row level security;

revoke all on public.customer_accounts, public.customer_ledger, public.loyalty_ledger, public.customer_payments from anon;
revoke insert, update, delete on public.customer_accounts, public.customer_ledger, public.loyalty_ledger,
  public.customer_payments from authenticated;
grant select on public.customer_accounts, public.customer_ledger, public.loyalty_ledger, public.customer_payments
  to authenticated;
revoke usage on sequence public.collection_seq from anon;

create policy customer_accounts_select on public.customer_accounts for select to authenticated using (public.is_staff());
create policy customer_ledger_select on public.customer_ledger for select to authenticated using (public.is_staff());
create policy loyalty_ledger_select on public.loyalty_ledger for select to authenticated using (public.is_staff());
create policy customer_payments_select on public.customer_payments for select to authenticated using (public.is_staff());

create trigger customer_payments_audit after insert or update or delete on public.customer_payments
  for each row execute function public.audit_trigger();

revoke execute on function
  public.record_customer_payment(uuid, numeric, public.collection_method, public.collection_kind, text, text, uuid, uuid),
  public.void_customer_payment(uuid, text),
  public.set_credit_limit(uuid, numeric),
  public.adjust_loyalty(uuid, integer, text),
  public.customer_statement(uuid, date, date),
  public.receivables_report()
from public, anon;
grant execute on function
  public.record_customer_payment(uuid, numeric, public.collection_method, public.collection_kind, text, text, uuid, uuid),
  public.void_customer_payment(uuid, text),
  public.set_credit_limit(uuid, numeric),
  public.adjust_loyalty(uuid, integer, text),
  public.customer_statement(uuid, date, date),
  public.receivables_report()
to authenticated;

-- =====================================================================
-- 0010_promotions_reservations.sql
-- =====================================================================
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

-- =====================================================================
-- 0011_sales_v2.sql
-- =====================================================================
-- =====================================================================
-- Sales & Customers 2.0 — (3) البيع 2.0
--   • تسعير السلة في الخادم فقط (_price_cart): العروض، الكوبون، خصم الكاشير، استبدال النقاط، الضريبة.
--     نفس الدالة تُستخدم للمعاينة في الشاشة ولإتمام البيع، فلا يختلف ما يراه الكاشير عمّا يُحفظ
--   • complete_sale بمعاملات إضافية اختيارية (التوافق الكامل مع الاستدعاءات السابقة):
--       p_client_ref     : مفتاح منع التكرار — نفس المفتاح يعيد نفس الفاتورة ولا يُنشئ أخرى
--       p_promo_code     : كوبون
--       p_redeem_points  : نقاط تُستبدل كخصم (الضريبة تُحسب بعد الخصم وفق قواعد الهيئة)
--       p_reservation_id : استلام حجز
--     والدفع «آجل» (on_account) لعميل ضمن حد ائتمانه، مع قيد في دفتر الذمم
--   • المرتجع: «إلى حساب العميل» يُنقص الذمة، ونقاط الفاتورة تُعكس بنسبة المرتجع — عبر trigger
--     دون تعديل process_return
--   • رمز عام لكل فاتورة (public_token) لعرضها للعميل واسترجاعها بالـ QR في المرتجع/الاستبدال
-- =====================================================================

alter table public.sales
  add column client_ref uuid unique,
  add column promo_code text,
  add column promo_discount numeric(12,2) not null default 0,
  add column loyalty_points_redeemed integer not null default 0,
  add column loyalty_discount numeric(12,2) not null default 0,     -- بأساس السعر (مثل بقية الخصومات)
  add column loyalty_points_earned integer not null default 0,
  add column reservation_id uuid references public.reservations (id),
  add column public_token text not null unique default replace(gen_random_uuid()::text, '-', '');

alter table public.sale_items
  add column promo_discount numeric(12,2) not null default 0,       -- جزء من line_discount
  add column promotion_id uuid references public.promotions (id) on delete set null;

grant select (promo_discount, promotion_id) on public.sale_items to authenticated;

-- ---------------------------------------------------------------------
-- تقييم عرض واحد على أسطر السلة التي لم يأخذها عرض آخر
--   يعيد: {"total": n, "alloc": [خصم كل سطر], "consumed": [هل السطر محجوز لهذا العرض]}
-- ---------------------------------------------------------------------
create or replace function public._promo_eval(p public.promotions, p_lines jsonb, p_taken boolean[])
returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  n integer := jsonb_array_length(p_lines);
  v_alloc numeric[] := array_fill(0::numeric, array[n]);
  v_cons boolean[] := array_fill(false, array[n]);
  v_units integer := 0;
  v_free integer;
  v_take integer;
  v_total numeric := 0;
  v_line jsonb;
  i integer;
  r record;
begin
  for i in 1 .. n loop
    v_line := p_lines -> (i - 1);
    if not p_taken[i] and (
         p.scope = 'all'
      or (p.scope = 'category' and (v_line ->> 'category_id')::uuid = p.category_id)
      or (p.scope = 'product' and (v_line ->> 'product_id')::uuid = p.product_id)) then
      v_cons[i] := true;
      v_units := v_units + (v_line ->> 'qty')::integer;
    end if;
  end loop;

  if v_units = 0 or v_units < p.min_qty then
    return jsonb_build_object('total', 0);
  end if;

  if p.kind = 'bxgy' then
    v_free := (v_units / (p.buy_qty + p.get_qty)) * p.get_qty;
    if v_free = 0 then
      return jsonb_build_object('total', 0);
    end if;
    -- القطع المجانية = الأرخص بين الأصناف المشمولة
    for r in
      select (x.ord)::integer as idx, (x.l ->> 'qty')::integer as qty, (x.l ->> 'unit_price')::numeric as price
        from jsonb_array_elements(p_lines) with ordinality as x(l, ord)
       order by (x.l ->> 'unit_price')::numeric, x.ord
    loop
      exit when v_free = 0;
      if v_cons[r.idx] then
        v_take := least(r.qty, v_free);
        v_alloc[r.idx] := round(v_take * r.price, 2);
        v_free := v_free - v_take;
      end if;
    end loop;
  else
    for i in 1 .. n loop
      if v_cons[i] then
        v_line := p_lines -> (i - 1);
        if p.kind = 'percent' then
          v_alloc[i] := round((v_line ->> 'gross')::numeric * p.value / 100, 2);
        else
          v_alloc[i] := least(round(p.value * (v_line ->> 'qty')::integer, 2), (v_line ->> 'gross')::numeric);
        end if;
      end if;
    end loop;
    -- عروض النسبة/المبلغ لا تحجز إلا الأسطر التي خُصم منها فعلاً
    for i in 1 .. n loop
      v_cons[i] := v_cons[i] and v_alloc[i] > 0;
    end loop;
  end if;

  for i in 1 .. n loop
    v_total := v_total + v_alloc[i];
  end loop;
  return jsonb_build_object('total', v_total, 'alloc', to_jsonb(v_alloc), 'consumed', to_jsonb(v_cons));
end;
$$;
revoke all on function public._promo_eval(public.promotions, jsonb, boolean[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- تسعير السلة (داخلي). لا يكتب شيئاً.
-- ترتيب الخصومات على كل سطر: العرض (الأفضل للعميل، بلا تراكب عروض) ← خصم الكاشير على السطر
-- ثم على الفاتورة: خصم الكاشير + قيمة النقاط، موزعة على الأسطر نسبياً، ثم الضريبة لكل سطر
-- ---------------------------------------------------------------------
create or replace function public._price_cart(
  p_items jsonb,
  p_invoice_discount numeric,
  p_promo_code text,
  p_redeem_points integer,
  p_customer_id uuid,
  p_role public.user_role
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s public.store_settings;
  v_item jsonb;
  v_variant record;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  n integer;
  i integer;
  v_qty integer;
  v_code text := nullif(upper(trim(p_promo_code)), '');
  v_code_applied boolean := false;
  v_taken boolean[];
  v_promo public.promotions;
  v_eval jsonb;
  v_best jsonb;
  v_best_promo public.promotions;
  v_best_total numeric;
  v_applied jsonb := '[]'::jsonb;
  v_gross numeric;
  v_promo_amt numeric;
  v_disc numeric;
  v_sum_gross numeric := 0;
  v_sum_promo numeric := 0;
  v_sum_manual numeric := 0;
  v_base numeric;
  v_inv_disc numeric;
  v_points integer := greatest(coalesce(p_redeem_points, 0), 0);
  v_loyalty_value numeric := 0;
  v_loyalty_base numeric := 0;
  v_loyalty_cap numeric;
  v_alloc_total numeric;
  v_alloc numeric;
  v_alloc_done numeric := 0;
  v_net numeric;
  v_line_total numeric;
  v_line_vat numeric;
  v_total numeric := 0;
  v_vat numeric := 0;
begin
  select * into s from public.store_settings where id = 1;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'السلة فارغة';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      raise exception 'كمية غير صحيحة';
    end if;
    select v.id, v.sku, v.size, v.color, coalesce(v.price, p.base_price) as price, p.name, p.id as product_id,
           p.category_id, v.is_active and p.is_active as active, coalesce(c.cost_price, 0) as cost
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
    v_lines := v_lines || jsonb_build_object(
      'variant_id', v_variant.id, 'sku', v_variant.sku, 'product_name', v_variant.name,
      'variant_label', nullif(concat_ws(' / ', v_variant.size, v_variant.color), ''),
      'product_id', v_variant.product_id, 'category_id', v_variant.category_id,
      'qty', v_qty, 'unit_price', v_variant.price, 'gross', round(v_variant.price * v_qty, 2),
      'manual', greatest(coalesce((v_item ->> 'discount')::numeric, 0), 0), 'cost', v_variant.cost,
      'promo', 0, 'promotion_id', null);
  end loop;
  n := jsonb_array_length(v_lines);
  v_taken := array_fill(false, array[n]);

  -- الكوبون يجب أن يكون صالحاً الآن
  if v_code is not null and not exists (
    select 1 from public.promotions
     where code = v_code and is_active
       and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())) then
    raise exception 'رمز الخصم «%» غير صالح أو منتهي الصلاحية', v_code;
  end if;

  -- اختيار العروض: كل جولة تأخذ العرض الأكبر خصماً على الأسطر المتبقية (بلا تراكب على نفس السطر)
  loop
    v_best := null;
    v_best_total := 0;
    for v_promo in
      select * from public.promotions
       where is_active
         and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())
         and (code is null or code = v_code)
       order by created_at, id
    loop
      v_eval := public._promo_eval(v_promo, v_lines, v_taken);
      if (v_eval ->> 'total')::numeric > v_best_total then
        v_best := v_eval;
        v_best_total := (v_eval ->> 'total')::numeric;
        v_best_promo := v_promo;
      end if;
    end loop;
    exit when v_best is null;

    for i in 1 .. n loop
      if (v_best -> 'consumed' ->> (i - 1))::boolean then
        v_taken[i] := true;
        v_lines := jsonb_set(v_lines, array[(i - 1)::text], (v_lines -> (i - 1)) || jsonb_build_object(
          'promo', (v_best -> 'alloc' ->> (i - 1))::numeric,
          'promotion_id', case when (v_best -> 'alloc' ->> (i - 1))::numeric > 0 then v_best_promo.id end));
      end if;
    end loop;
    v_applied := v_applied || jsonb_build_object('id', v_best_promo.id, 'name', v_best_promo.name,
                                                 'code', v_best_promo.code, 'discount', v_best_total);
    if v_best_promo.code is not null then
      v_code_applied := true;
    end if;
  end loop;

  -- خصم الكاشير على السطر: لا يتجاوز ما بقي بعد العرض
  for i in 0 .. n - 1 loop
    v_line := v_lines -> i;
    v_gross := (v_line ->> 'gross')::numeric;
    v_promo_amt := (v_line ->> 'promo')::numeric;
    v_disc := round(least((v_line ->> 'manual')::numeric, v_gross - v_promo_amt), 2);
    v_lines := jsonb_set(v_lines, array[i::text], v_line || jsonb_build_object('manual', v_disc));
    v_sum_gross := v_sum_gross + v_gross;
    v_sum_promo := v_sum_promo + v_promo_amt;
    v_sum_manual := v_sum_manual + v_disc;
  end loop;

  v_base := v_sum_gross - v_sum_promo - v_sum_manual;
  v_inv_disc := round(least(greatest(coalesce(p_invoice_discount, 0), 0), v_base), 2);

  -- حد الخصم للكاشير: يشمل خصوماته اليدوية فقط (العروض والنقاط خصومات النظام)
  if p_role = 'cashier' and v_sum_gross > 0
     and (v_sum_manual + v_inv_disc) / v_sum_gross * 100 > s.max_cashier_discount_pct + 0.001 then
    raise exception 'الخصم يتجاوز الحد المسموح للكاشير (% %%)', s.max_cashier_discount_pct;
  end if;

  -- استبدال النقاط
  if v_points > 0 then
    if not s.loyalty_enabled then
      raise exception 'برنامج الولاء غير مفعّل';
    end if;
    if p_customer_id is null then
      raise exception 'اختر العميل لاستبدال النقاط';
    end if;
    if v_points < s.loyalty_min_redeem then
      raise exception 'الحد الأدنى للاستبدال % نقطة', s.loyalty_min_redeem;
    end if;
    if v_points > coalesce((select loyalty_points from public.customer_accounts where customer_id = p_customer_id), 0) then
      raise exception 'رصيد النقاط غير كافٍ';
    end if;
    v_loyalty_value := round(v_points * s.loyalty_point_value, 2);
    v_loyalty_base := case when s.prices_include_vat then v_loyalty_value
                           else round(v_loyalty_value * 100 / (100 + s.vat_rate), 2) end;
    v_loyalty_cap := round((v_base - v_inv_disc) * s.loyalty_max_redeem_pct / 100, 2);
    if v_loyalty_base > v_loyalty_cap + 0.001 then
      raise exception 'قيمة النقاط (% ر.س) تتجاوز الحد المسموح (% %% من الفاتورة)', v_loyalty_value, s.loyalty_max_redeem_pct;
    end if;
  end if;

  -- توزيع خصم الفاتورة + النقاط على الأسطر، ثم الضريبة (نفس خوارزمية complete_sale السابقة)
  v_alloc_total := v_inv_disc + v_loyalty_base;
  for i in 0 .. n - 1 loop
    v_line := v_lines -> i;
    v_net := (v_line ->> 'gross')::numeric - (v_line ->> 'promo')::numeric - (v_line ->> 'manual')::numeric;
    if i = n - 1 then
      v_alloc := v_alloc_total - v_alloc_done;
    elsif v_base > 0 then
      v_alloc := round(v_alloc_total * v_net / v_base, 2);
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
    v_lines := jsonb_set(v_lines, array[i::text], v_line || jsonb_build_object(
      'line_discount', (v_line ->> 'manual')::numeric + (v_line ->> 'promo')::numeric + v_alloc,
      'line_total', v_line_total,
      'vat', v_line_vat));
  end loop;

  return jsonb_build_object(
    'lines', v_lines,
    'gross', v_sum_gross,
    'promo_discount', v_sum_promo,
    'manual_discount', v_sum_manual,
    'invoice_discount', v_inv_disc,
    'loyalty_points', v_points,
    'loyalty_value', v_loyalty_value,
    'loyalty_discount', v_loyalty_base,
    'discount_total', v_sum_promo + v_sum_manual + v_inv_disc + v_loyalty_base,
    'subtotal', v_total - v_vat,
    'vat', v_vat,
    'total', v_total,
    'promotions', v_applied,
    'promo_code', v_code,
    'promo_code_applied', v_code_applied
  );
end;
$$;
revoke all on function public._price_cart(jsonb, numeric, text, integer, uuid, public.user_role) from public, anon, authenticated;

-- معاينة السلة للشاشة (نفس حسابات إتمام البيع) + ما يحتاجه الكاشير عن العميل
create or replace function public.price_cart(
  p_items jsonb,
  p_invoice_discount numeric default 0,
  p_promo_code text default null,
  p_redeem_points integer default 0,
  p_customer_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_acc public.customer_accounts;
  v_result jsonb;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.store_settings where id = 1;
  v_result := public._price_cart(p_items, p_invoice_discount, p_promo_code, p_redeem_points, p_customer_id, v_role);
  if p_customer_id is not null then
    select * into v_acc from public.customer_accounts where customer_id = p_customer_id;
    v_result := v_result || jsonb_build_object('customer', jsonb_build_object(
      'loyalty_points', coalesce(v_acc.loyalty_points, 0),
      'account_balance', coalesce(v_acc.account_balance, 0),
      'credit_limit', v_acc.credit_limit,
      'credit_available', greatest(coalesce(v_acc.credit_limit, 0) - coalesce(v_acc.account_balance, 0), 0),
      'can_use_credit', (v_role <> 'cashier' or s.allow_cashier_credit)
    ));
  end if;
  -- قطع لا يمكن بيعها لأنها محجوزة لعملاء آخرين
  return v_result || jsonb_build_object('reserved', coalesce((
    select jsonb_object_agg(l ->> 'variant_id', public._reserved_qty((l ->> 'variant_id')::uuid))
      from jsonb_array_elements(v_result -> 'lines') l
     where public._reserved_qty((l ->> 'variant_id')::uuid) > 0), '{}'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- إتمام البيع 2.0 — يحل محل النسخة السابقة بنفس المعاملات الخمسة الأولى
-- ---------------------------------------------------------------------
drop function public.complete_sale(jsonb, jsonb, uuid, numeric, text);

create or replace function public.complete_sale(
  p_items jsonb,
  p_payments jsonb,
  p_customer_id uuid default null,
  p_invoice_discount numeric default 0,
  p_notes text default null,
  p_client_ref uuid default null,
  p_promo_code text default null,
  p_redeem_points integer default 0,
  p_reservation_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_existing public.sales;
  v_res public.reservations;
  v_customer uuid := p_customer_id;
  v_acc public.customer_accounts;
  v_price jsonb;
  v_line jsonb;
  v_pay jsonb;
  v_sale_id uuid;
  v_invoice_no text;
  v_total numeric;
  v_paid numeric := 0;
  v_noncash numeric := 0;
  v_on_account numeric := 0;
  v_exchange numeric := 0;
  v_change numeric;
  v_method public.payment_method;
  v_amount numeric;
  v_return public.returns;
  v_points integer := greatest(coalesce(p_redeem_points, 0), 0);
  v_earn integer := 0;
  v_available integer;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.store_settings where id = 1;

  -- منع الترحيل المزدوج: نفس المفتاح = نفس الفاتورة
  if p_client_ref is not null then
    select * into v_existing from public.sales where client_ref = p_client_ref;
    if v_existing.id is not null then
      if v_existing.cashier_id is distinct from auth.uid() then
        raise exception 'مرجع العملية مستخدم مسبقاً';
      end if;
      return v_existing.id;
    end if;
  end if;

  -- استلام حجز
  if p_reservation_id is not null then
    select * into v_res from public.reservations where id = p_reservation_id for update;
    if v_res.id is null or v_res.status <> 'active' then
      raise exception 'الحجز غير موجود أو تم إغلاقه';
    end if;
    if v_customer is null then
      v_customer := v_res.customer_id;
    elsif v_customer <> v_res.customer_id then
      raise exception 'الحجز لعميل آخر';
    end if;
  end if;

  if v_customer is not null and not exists (select 1 from public.customers where id = v_customer) then
    raise exception 'العميل غير موجود';
  end if;
  -- قفل حساب العميل قبل التحقق من النقاط/الائتمان
  if v_customer is not null then
    v_acc := public._customer_account(v_customer);
  end if;

  v_price := public._price_cart(p_items, p_invoice_discount, p_promo_code, v_points, v_customer, v_role);
  v_total := (v_price ->> 'total')::numeric;

  -- الكميات المحجوزة لعملاء آخرين لا تُباع
  if not s.allow_negative_stock then
    for v_line in
      select jsonb_build_object('variant_id', l ->> 'variant_id', 'sku', min(l ->> 'sku'), 'qty', sum((l ->> 'qty')::integer))
        from jsonb_array_elements(v_price -> 'lines') l group by l ->> 'variant_id'
    loop
      select stock_qty - public._reserved_qty(id, p_reservation_id) into v_available
        from public.product_variants where id = (v_line ->> 'variant_id')::uuid for update;
      if (v_line ->> 'qty')::integer > v_available then
        raise exception 'المتاح من الصنف % هو % فقط (الباقي محجوز لعملاء)', v_line ->> 'sku', greatest(v_available, 0);
      end if;
    end loop;
  end if;

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
      select * into v_return from public.returns where id = (v_pay ->> 'return_id')::uuid for update;
      if v_return.id is null or v_return.refund_method <> 'exchange' then
        raise exception 'رصيد الاستبدال غير صالح';
      end if;
      if v_return.credit_used_by_sale is not null then
        raise exception 'رصيد الاستبدال % مستخدم مسبقاً', v_return.return_no;
      end if;
      if v_amount <> v_return.total then
        raise exception 'يجب استخدام رصيد الاستبدال كاملاً (% ر.س)', v_return.total;
      end if;
      v_exchange := v_exchange + v_amount;
    elsif v_method = 'on_account' then
      v_on_account := v_on_account + v_amount;
    end if;
    if v_method = 'cash' then
      null;
    else
      v_noncash := v_noncash + v_amount;
    end if;
    v_paid := v_paid + v_amount;
  end loop;

  if v_noncash > v_total + 0.001 then
    raise exception 'مبالغ الشبكة/التحويل/الاستبدال/الآجل (% ) أكبر من إجمالي الفاتورة (% )', v_noncash, v_total;
  end if;
  if v_paid + 0.001 < v_total then
    raise exception 'المبلغ المدفوع (% ) أقل من الإجمالي (% )', v_paid, v_total;
  end if;
  v_change := round(v_paid - v_total, 2);

  -- البيع الآجل
  if v_on_account > 0 then
    if v_customer is null then
      raise exception 'البيع الآجل يتطلب اختيار العميل';
    end if;
    if v_role = 'cashier' and not s.allow_cashier_credit then
      raise exception 'البيع الآجل غير مسموح للكاشير';
    end if;
    if v_acc.account_balance + v_on_account > coalesce(v_acc.credit_limit, 0) + 0.001 then
      raise exception 'يتجاوز حد الائتمان للعميل (الحد % ر.س، الرصيد الحالي % ر.س)',
        coalesce(v_acc.credit_limit, 0), v_acc.account_balance;
    end if;
  end if;

  v_invoice_no := 'INV-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.invoice_seq')::text, 6, '0');
  insert into public.sales (
    invoice_no, customer_id, cashier_id, subtotal, discount_total, invoice_discount,
    vat_rate, vat_amount, total, paid_amount, change_amount, notes,
    client_ref, promo_code, promo_discount, loyalty_points_redeemed, loyalty_discount, reservation_id
  ) values (
    v_invoice_no, v_customer, auth.uid(), (v_price ->> 'subtotal')::numeric, (v_price ->> 'discount_total')::numeric,
    (v_price ->> 'invoice_discount')::numeric, s.vat_rate, (v_price ->> 'vat')::numeric, v_total, v_paid, v_change,
    nullif(trim(p_notes), ''),
    p_client_ref, case when (v_price ->> 'promo_code_applied')::boolean then v_price ->> 'promo_code' end,
    (v_price ->> 'promo_discount')::numeric, v_points, (v_price ->> 'loyalty_discount')::numeric, p_reservation_id
  ) returning id into v_sale_id;

  insert into public.sale_items (
    sale_id, variant_id, product_name, variant_label, sku, qty, unit_price,
    line_discount, line_total, vat_amount, unit_cost, promo_discount, promotion_id
  )
  select v_sale_id, (l ->> 'variant_id')::uuid, l ->> 'product_name', l ->> 'variant_label',
         l ->> 'sku', (l ->> 'qty')::integer, (l ->> 'unit_price')::numeric,
         (l ->> 'line_discount')::numeric, (l ->> 'line_total')::numeric,
         (l ->> 'vat')::numeric, (l ->> 'cost')::numeric,
         (l ->> 'promo')::numeric, (l ->> 'promotion_id')::uuid
    from jsonb_array_elements(v_price -> 'lines') l;

  for v_line in select * from jsonb_array_elements(v_price -> 'lines') loop
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
      update public.returns set credit_used_by_sale = v_sale_id where id = (v_pay ->> 'return_id')::uuid;
    end if;
  end loop;

  -- الذمم: قيد مدين بالمبلغ الآجل (قيد واحد لكل فاتورة — القيد الفريد يمنع التكرار)
  if v_on_account > 0 then
    perform public._post_ar(v_customer, 'sale', v_sale_id, v_invoice_no, v_on_account, 0, null);
  end if;

  -- الولاء: خصم المستبدل، ثم كسب نقاط على المدفوع فعلاً: بدون رصيد الاستبدال، وبدون الآجل
  -- إلا ما غطّاه رصيد دائن سابق للعميل (عربون مدفوع مسبقاً = مدفوع فعلاً)
  if v_customer is not null then
    if v_points > 0 then
      perform public._post_loyalty(v_customer, 'redeem', v_sale_id, v_invoice_no, -v_points, null);
    end if;
    if s.loyalty_enabled then
      v_earn := floor(greatest(
        v_total - v_exchange - (v_on_account - least(v_on_account, greatest(-v_acc.account_balance, 0))), 0)
        * s.loyalty_points_per_sar)::integer;
      if v_earn > 0 then
        perform public._post_loyalty(v_customer, 'earn', v_sale_id, v_invoice_no, v_earn, null);
        update public.sales set loyalty_points_earned = v_earn where id = v_sale_id;
      end if;
    end if;
  end if;

  if p_reservation_id is not null then
    update public.reservations
       set status = 'fulfilled', sale_id = v_sale_id, closed_at = now(), closed_by = auth.uid()
     where id = p_reservation_id;
  end if;

  return v_sale_id;
end;
$$;

-- ---------------------------------------------------------------------
-- المرتجع: ربط الذمم والنقاط (بعد أن يحدد process_return إجمالي المرتجع)
-- ---------------------------------------------------------------------
create or replace function public.on_return_posted()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_sale public.sales;
  v_on_account numeric;
  v_paid_now numeric;
  v_prev numeric;
  v_earned integer;
  v_redeemed integer;
  v_done integer;
  v_ratio numeric;
  v_delta integer;
begin
  select * into v_sale from public.sales where id = new.sale_id;

  if new.refund_method = 'account' then
    if v_sale.customer_id is null then
      raise exception 'الإرجاع إلى الحساب يتطلب فاتورة باسم عميل';
    end if;
    perform public._post_ar(v_sale.customer_id, 'return', new.id, new.return_no, 0, new.total, v_sale.invoice_no);
  else
    -- فاتورة فيها جزء آجل: لا يُرد نقداً/شبكة/استبدال أكثر مما دُفع فعلاً عند البيع
    select coalesce(sum(amount) filter (where method = 'on_account'), 0),
           coalesce(sum(amount) filter (where method <> 'on_account'), 0) - v_sale.change_amount
      into v_on_account, v_paid_now
      from public.sale_payments where sale_id = v_sale.id;
    if v_on_account > 0 then
      select coalesce(sum(total), 0) into v_prev from public.returns
       where sale_id = v_sale.id and id <> new.id and refund_method <> 'account';
      if v_prev + new.total > v_paid_now + 0.001 then
        raise exception 'جزء من هذه الفاتورة آجل: الحد الأقصى للرد بهذه الطريقة % ر.س — اختر «إلى حساب العميل»',
          greatest(v_paid_now - v_prev, 0);
      end if;
    end if;
  end if;

  -- النقاط: عكس المكتسب واسترجاع المستبدل بنسبة ما أُرجع من الفاتورة (تراكمياً لتفادي فروق التقريب)
  if v_sale.customer_id is not null and v_sale.total > 0 then
    v_ratio := least((select coalesce(sum(total), 0) from public.returns where sale_id = v_sale.id) / v_sale.total, 1);
    select coalesce(sum(points), 0) into v_earned from public.loyalty_ledger
     where entry_type = 'earn' and source_id = v_sale.id;
    select -coalesce(sum(points), 0) into v_redeemed from public.loyalty_ledger
     where entry_type = 'redeem' and source_id = v_sale.id;

    if v_earned > 0 then
      select -coalesce(sum(l.points), 0) into v_done from public.loyalty_ledger l
        join public.returns r on r.id = l.source_id
       where l.entry_type = 'return_reverse' and r.sale_id = v_sale.id;
      v_delta := round(v_earned * v_ratio)::integer - v_done;
      if v_delta > 0 then
        perform public._post_loyalty(v_sale.customer_id, 'return_reverse', new.id, new.return_no, -v_delta, v_sale.invoice_no);
      end if;
    end if;
    if v_redeemed > 0 then
      select coalesce(sum(l.points), 0) into v_done from public.loyalty_ledger l
        join public.returns r on r.id = l.source_id
       where l.entry_type = 'return_restore' and r.sale_id = v_sale.id;
      v_delta := round(v_redeemed * v_ratio)::integer - v_done;
      if v_delta > 0 then
        perform public._post_loyalty(v_sale.customer_id, 'return_restore', new.id, new.return_no, v_delta, v_sale.invoice_no);
      end if;
    end if;
  end if;
  return new;
end;
$$;

create trigger returns_posted after update of total on public.returns
  for each row when (old.total = 0 and new.total > 0)
  execute function public.on_return_posted();

-- ---------------------------------------------------------------------
-- الفاتورة للعميل برابط/QR (بدون تسجيل دخول) — بيانات الفاتورة فقط، دون بيانات العميل أو التكلفة
-- ---------------------------------------------------------------------
create or replace function public.public_receipt(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v public.sales;
  s public.store_settings;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return null;
  end if;
  select * into v from public.sales where public_token = p_token;
  if v.id is null then
    return null;
  end if;
  select * into s from public.store_settings where id = 1;
  return jsonb_build_object(
    'store', jsonb_build_object('name', s.store_name, 'name_en', s.store_name_en, 'vat_number', s.vat_number,
                                'cr_number', s.cr_number, 'phone', s.phone, 'address', s.address,
                                'footer', s.receipt_footer, 'prices_include_vat', s.prices_include_vat),
    'invoice_no', v.invoice_no, 'created_at', v.created_at, 'status', v.status,
    'subtotal', v.subtotal, 'discount_total', v.discount_total, 'vat_rate', v.vat_rate, 'vat_amount', v.vat_amount,
    'total', v.total, 'paid_amount', v.paid_amount, 'change_amount', v.change_amount,
    'returned_amount', v.returned_amount, 'loyalty_points_earned', v.loyalty_points_earned,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
               'product_name', i.product_name, 'variant_label', i.variant_label, 'qty', i.qty,
               'unit_price', i.unit_price, 'line_discount', i.line_discount, 'line_total', i.line_total,
               'returned_qty', i.returned_qty) order by i.product_name)
               from public.sale_items i where i.sale_id = v.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', p.method, 'amount', p.amount))
               from public.sale_payments p where p.sale_id = v.id), '[]'::jsonb)
  );
end;
$$;

-- استرجاع رقم الفاتورة من: رقم الفاتورة، أو الرمز، أو رابط QR (للمرتجع/الاستبدال)
create or replace function public.resolve_invoice_ref(p_ref text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_ref text := trim(coalesce(p_ref, ''));
  v_token text;
  v_no text;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  v_token := substring(v_ref from '([0-9a-f]{32})');
  if v_token is not null then
    select invoice_no into v_no from public.sales where public_token = v_token;
  end if;
  if v_no is null then
    select invoice_no into v_no from public.sales where upper(invoice_no) = upper(v_ref);
  end if;
  if v_no is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  return v_no;
end;
$$;

-- سياق المرتجع: العميل والجزء الآجل ونقاط الفاتورة (لشاشة المرتجعات — بنفس صلاحية get_sale_for_return)
create or replace function public.sale_return_context(p_sale_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v public.sales;
  v_on_account numeric;
  v_paid_now numeric;
  v_refunded numeric;
begin
  select * into s from public.store_settings where id = 1;
  if v_role is null or (v_role = 'cashier' and not s.allow_cashier_returns) then
    raise exception 'غير مصرح بعمليات الإرجاع';
  end if;
  select * into v from public.sales where id = p_sale_id;
  if v.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  select coalesce(sum(amount) filter (where method::text = 'on_account'), 0),
         coalesce(sum(amount) filter (where method::text <> 'on_account'), 0) - v.change_amount
    into v_on_account, v_paid_now
    from public.sale_payments where sale_id = v.id;
  select coalesce(sum(total), 0) into v_refunded from public.returns
   where sale_id = v.id and refund_method::text <> 'account';
  return jsonb_build_object(
    'customer_id', v.customer_id,
    'customer_phone', (select phone from public.customers where id = v.customer_id),
    'on_account', v_on_account,
    'max_direct_refund', case when v_on_account > 0 then greatest(v_paid_now - v_refunded, 0) end,
    'loyalty_points_earned', v.loyalty_points_earned,
    'loyalty_points_redeemed', v.loyalty_points_redeemed
  );
end;
$$;

-- ---------------------------------------------------------------------
-- سجل رسائل واتساب (فتح المحادثة من النظام)
-- ---------------------------------------------------------------------
create table public.message_log (
  id uuid primary key default gen_random_uuid(),
  channel text not null default 'whatsapp' check (channel in ('whatsapp')),
  kind text not null check (kind in ('receipt', 'statement', 'reservation', 'reminder')),
  sale_id uuid references public.sales (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  reservation_id uuid references public.reservations (id) on delete set null,
  phone text not null check (phone ~ '^[0-9]{8,15}$'),
  created_by uuid not null references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index message_log_customer_idx on public.message_log (customer_id, created_at desc);
create index message_log_sale_idx on public.message_log (sale_id);

alter table public.message_log enable row level security;
revoke all on public.message_log from anon;
revoke update, delete on public.message_log from authenticated;
grant select, insert on public.message_log to authenticated;
create policy message_log_select on public.message_log for select to authenticated using (public.is_staff());
create policy message_log_insert on public.message_log for insert to authenticated
  with check (public.is_staff() and created_by = auth.uid());

-- ---------------------------------------------------------------------
-- الصلاحيات
-- ---------------------------------------------------------------------
revoke execute on function
  public.complete_sale(jsonb, jsonb, uuid, numeric, text, uuid, text, integer, uuid),
  public.price_cart(jsonb, numeric, text, integer, uuid),
  public.resolve_invoice_ref(text),
  public.sale_return_context(uuid),
  public.public_receipt(text),
  public.on_return_posted()
from public, anon;
grant execute on function
  public.complete_sale(jsonb, jsonb, uuid, numeric, text, uuid, text, integer, uuid),
  public.price_cart(jsonb, numeric, text, integer, uuid),
  public.resolve_invoice_ref(text),
  public.sale_return_context(uuid)
to authenticated;
-- الرابط العام للفاتورة: للزائر والمسجل
grant execute on function public.public_receipt(text) to anon, authenticated;

-- =====================================================================
-- 0012_customer_insights.sql
-- =====================================================================
-- =====================================================================
-- Sales & Customers 2.0 — (4) ملف العميل الشامل + تحليلات العملاء
--   قراءة فقط. لا تكلفة ولا أرباح في ملف العميل (يراه الكاشير أيضاً).
-- =====================================================================

create or replace function public.customer_profile(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_c public.customers;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select * into v_c from public.customers where id = p_customer_id;
  if v_c.id is null then
    raise exception 'العميل غير موجود';
  end if;

  return (
    with s as (select * from public.sales where customer_id = p_customer_id),
    items as (
      select i.*, v.size, v.color, c.name as category
        from public.sale_items i
        join s on s.id = i.sale_id
        join public.product_variants v on v.id = i.variant_id
        join public.products p on p.id = v.product_id
        left join public.categories c on c.id = p.category_id
    )
    select jsonb_build_object(
      'customer', to_jsonb(v_c),
      'account', (select jsonb_build_object('account_balance', coalesce(a.account_balance, 0),
                                            'credit_limit', a.credit_limit,
                                            'loyalty_points', coalesce(a.loyalty_points, 0))
                    from (select 1) x left join public.customer_accounts a on a.customer_id = p_customer_id),
      'stats', (select jsonb_build_object(
                  'invoices', count(*),
                  'gross_spent', coalesce(sum(total), 0),
                  'returned', coalesce(sum(returned_amount), 0),
                  'net_spent', coalesce(sum(total - returned_amount), 0),
                  'avg_basket', case when count(*) > 0 then round(sum(total - returned_amount) / count(*), 2) else 0 end,
                  'first_purchase', min(created_at),
                  'last_purchase', max(created_at),
                  'days_since_last', (now() at time zone 'Asia/Riyadh')::date - (max(created_at) at time zone 'Asia/Riyadh')::date,
                  'units', coalesce((select sum(qty - returned_qty) from items), 0),
                  'promo_savings', coalesce(sum(promo_discount), 0),
                  'points_redeemed', coalesce(sum(loyalty_points_redeemed), 0)
                ) from s),
      'favorite_sizes', coalesce((select jsonb_agg(x) from (
          select size as label, sum(qty - returned_qty) as units from items where size is not null
           group by size having sum(qty - returned_qty) > 0 order by 2 desc, 1 limit 3) x), '[]'::jsonb),
      'favorite_colors', coalesce((select jsonb_agg(x) from (
          select color as label, sum(qty - returned_qty) as units from items where color is not null
           group by color having sum(qty - returned_qty) > 0 order by 2 desc, 1 limit 3) x), '[]'::jsonb),
      'favorite_categories', coalesce((select jsonb_agg(x) from (
          select category as label, sum(qty - returned_qty) as units from items where category is not null
           group by category having sum(qty - returned_qty) > 0 order by 2 desc, 1 limit 3) x), '[]'::jsonb),
      'purchases', coalesce((select jsonb_agg(x order by x.created_at desc) from (
          select s.id, s.invoice_no, s.created_at, s.total, s.returned_amount, s.status, s.public_token,
                 s.cashier_id = auth.uid() as is_mine,
                 (select sum(qty) from public.sale_items where sale_id = s.id) as units,
                 (select string_agg(distinct method::text, ',') from public.sale_payments where sale_id = s.id) as methods,
                 (select string_agg(product_name || coalesce(' ' || variant_label, ''), '، ' order by product_name)
                    from public.sale_items where sale_id = s.id) as summary
            from s order by s.created_at desc limit 50) x), '[]'::jsonb),
      'reservations', coalesce((select jsonb_agg(x order by x.created_at desc) from (
          select r.id, r.reservation_no, r.status, r.expires_at, r.created_at, r.notes,
                 r.status = 'active' and r.expires_at <= now() as expired,
                 (select jsonb_agg(jsonb_build_object('variant_id', i.variant_id, 'qty', i.qty, 'sku', v.sku,
                                                      'product_name', p.name,
                                                      'variant_label', nullif(concat_ws(' / ', v.size, v.color), '')))
                    from public.reservation_items i
                    join public.product_variants v on v.id = i.variant_id
                    join public.products p on p.id = v.product_id
                   where i.reservation_id = r.id) as items
            from public.reservations r where r.customer_id = p_customer_id
           order by r.created_at desc limit 20) x), '[]'::jsonb),
      'loyalty', coalesce((select jsonb_agg(x order by x.id desc) from (
          select id, entry_type, ref_no, points, balance_after, note, created_at
            from public.loyalty_ledger where customer_id = p_customer_id order by id desc limit 30) x), '[]'::jsonb),
      'messages', (select count(*) from public.message_log where customer_id = p_customer_id)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- تحليلات العملاء (للمدير)
-- الشرائح بقواعد واضحة (R = أيام منذ آخر شراء، F = عدد الفواتير آخر 365 يوماً):
--   مميز: R ≤ 30 و F ≥ 4 | وفيّ: R ≤ 60 و F ≥ 2 | جديد: أول شراء خلال 30 يوماً
--   معرّض للفقد: 60 < R ≤ 120 و F ≥ 2 | مفقود: R > 120 | عرضي: غير ذلك
-- ---------------------------------------------------------------------
create or replace function public.customer_analytics(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamp at time zone 'Asia/Riyadh';
  v_to timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Riyadh';
  s public.store_settings;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'الفترة غير صحيحة';
  end if;
  select * into s from public.store_settings where id = 1;

  return (
    with ps as (select * from public.sales where created_at >= v_from and created_at < v_to),
    per_customer as (
      select customer_id, count(*) as invoices, sum(total - returned_amount) as net, max(created_at) as last_at
        from ps where customer_id is not null group by customer_id
    ),
    life as (
      select customer_id, min(created_at) as first_at, max(created_at) as last_at,
             count(*) filter (where created_at >= now() - interval '365 days') as f365,
             sum(total - returned_amount) filter (where created_at >= now() - interval '365 days') as m365
        from public.sales where customer_id is not null group by customer_id
    ),
    seg as (
      select l.*,
             (now() at time zone 'Asia/Riyadh')::date - (l.last_at at time zone 'Asia/Riyadh')::date as r,
             case
               when now() - l.last_at <= interval '30 days' and l.f365 >= 4 then 'champions'
               when now() - l.last_at <= interval '60 days' and l.f365 >= 2 then 'loyal'
               when now() - l.first_at <= interval '30 days' then 'new'
               when now() - l.last_at > interval '60 days' and now() - l.last_at <= interval '120 days' and l.f365 >= 2 then 'at_risk'
               when now() - l.last_at > interval '120 days' then 'lost'
               else 'occasional'
             end as segment
        from life l
    )
    select jsonb_build_object(
      'from', p_from, 'to', p_to,
      'customers_total', (select count(*) from public.customers),
      'customers_new', (select count(*) from public.customers where created_at >= v_from and created_at < v_to),
      'customers_active', (select count(*) from per_customer),
      'customers_returning', (select count(*) from per_customer pc join life l on l.customer_id = pc.customer_id
                               where l.first_at < v_from),
      'repeat_rate', case when (select count(*) from per_customer) > 0
                          then round(100.0 * (select count(*) from per_customer where invoices >= 2)
                                     / (select count(*) from per_customer), 1) else 0 end,
      'sales_registered', coalesce((select sum(total - returned_amount) from ps where customer_id is not null), 0),
      'sales_walkin', coalesce((select sum(total - returned_amount) from ps where customer_id is null), 0),
      'invoices_registered', (select count(*) from ps where customer_id is not null),
      'invoices_walkin', (select count(*) from ps where customer_id is null),
      'avg_basket_registered', coalesce((select round(avg(total - returned_amount), 2) from ps where customer_id is not null), 0),
      'avg_basket_walkin', coalesce((select round(avg(total - returned_amount), 2) from ps where customer_id is null), 0),
      'avg_spend_per_customer', coalesce((select round(avg(net), 2) from per_customer), 0),
      'top_customers', coalesce((select jsonb_agg(x order by x.net desc) from (
          select c.id, c.name, c.phone, pc.invoices, pc.net, pc.last_at,
                 coalesce(a.loyalty_points, 0) as loyalty_points, coalesce(a.account_balance, 0) as account_balance
            from per_customer pc join public.customers c on c.id = pc.customer_id
            left join public.customer_accounts a on a.customer_id = c.id
           order by pc.net desc limit 10) x), '[]'::jsonb),
      'segments', coalesce((select jsonb_object_agg(segment, jsonb_build_object('count', cnt, 'value', val)) from (
          select segment, count(*) as cnt, coalesce(sum(m365), 0) as val from seg group by segment) x), '{}'::jsonb),
      'at_risk_customers', coalesce((select jsonb_agg(x order by x.value desc) from (
          select c.id, c.name, c.phone, sg.r as days_since, sg.f365 as invoices, coalesce(sg.m365, 0) as value
            from seg sg join public.customers c on c.id = sg.customer_id
           where sg.segment = 'at_risk' order by sg.m365 desc nulls last limit 10) x), '[]'::jsonb),
      'loyalty', jsonb_build_object(
        'enabled', s.loyalty_enabled,
        'points_outstanding', coalesce((select sum(loyalty_points) from public.customer_accounts where loyalty_points > 0), 0),
        'liability', round(coalesce((select sum(loyalty_points) from public.customer_accounts where loyalty_points > 0), 0)
                           * s.loyalty_point_value, 2),
        'earned', coalesce((select sum(points) from public.loyalty_ledger
                             where entry_type = 'earn' and created_at >= v_from and created_at < v_to), 0),
        'redeemed', coalesce((select -sum(points) from public.loyalty_ledger
                               where entry_type = 'redeem' and created_at >= v_from and created_at < v_to), 0),
        'redeemed_value', coalesce((select sum(loyalty_discount) from ps), 0)),
      'credit', jsonb_build_object(
        'receivable', coalesce((select sum(account_balance) from public.customer_accounts where account_balance > 0), 0),
        'credit_balances', coalesce((select -sum(account_balance) from public.customer_accounts where account_balance < 0), 0),
        'credit_sales', coalesce((select sum(p.amount) from public.sale_payments p join ps on ps.id = p.sale_id
                                   where p.method::text = 'on_account'), 0),
        'collections', coalesce((select sum(amount) from public.customer_payments
                                  where kind = 'receipt' and voided_at is null
                                    and created_at >= v_from and created_at < v_to), 0)),
      'promotions', coalesce((select jsonb_agg(x order by x.discount desc) from (
          select pr.id, pr.name, pr.code, count(distinct i.sale_id) as invoices, sum(i.qty) as units,
                 sum(i.promo_discount) as discount, sum(i.line_total) as revenue
            from public.sale_items i join ps on ps.id = i.sale_id
            join public.promotions pr on pr.id = i.promotion_id
           group by pr.id, pr.name, pr.code) x), '[]'::jsonb),
      'reservations', jsonb_build_object(
        'active', (select count(*) from public.reservations where status = 'active' and expires_at > now()),
        'expired', (select count(*) from public.reservations where status = 'active' and expires_at <= now()),
        'fulfilled', (select count(*) from public.reservations where status = 'fulfilled'
                        and closed_at >= v_from and closed_at < v_to),
        'cancelled', (select count(*) from public.reservations where status = 'cancelled'
                        and closed_at >= v_from and closed_at < v_to)),
      'whatsapp_sent', (select count(*) from public.message_log where created_at >= v_from and created_at < v_to)
    )
  );
end;
$$;

revoke execute on function public.customer_profile(uuid), public.customer_analytics(date, date) from public, anon;
grant execute on function public.customer_profile(uuid), public.customer_analytics(date, date) to authenticated;

commit;
