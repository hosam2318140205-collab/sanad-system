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
