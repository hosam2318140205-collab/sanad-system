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
