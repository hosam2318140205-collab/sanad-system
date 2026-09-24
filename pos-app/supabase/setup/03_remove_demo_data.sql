-- =====================================================================
-- حذف البيانات التجريبية فقط (DEMO-) — لا يلمس منتجاتك أو عملاءك الحقيقيين
-- • الصنف التجريبي الذي لم يُبع: يُحذف مع مخزونه وحركاته.
-- • الصنف التجريبي الذي ظهر في فاتورة/مرتجع/أمر شراء: يُوقف فقط، لأن الفواتير سجلات
--   مالية لا تُحذف. لحذفه نهائياً شغّل 04_reset_test_transactions.sql أولاً ثم هذا الملف.
-- آمن للتكرار.
-- =====================================================================
do $$
declare
  v_deleted int;
  v_disabled int;
  v_customers int;
begin
  with demo as (
    select v.id, v.product_id,
           exists (select 1 from public.sale_items i where i.variant_id = v.id)
        or exists (select 1 from public.return_items r where r.variant_id = v.id)
        or exists (select 1 from public.purchase_items p where p.variant_id = v.id) as used
      from public.product_variants v
     where v.sku like 'DEMO-%'
  ),
  used_products as (select distinct product_id from demo where used),
  disabled as (
    update public.products p set is_active = false
     where p.id in (select product_id from used_products) and p.is_active
    returning p.id
  ),
  gone as (
    delete from public.products p
     where p.id in (select product_id from demo)
       and p.id not in (select product_id from used_products)
    returning p.id
  )
  select (select count(*) from gone), (select count(*) from disabled) into v_deleted, v_disabled;

  update public.product_variants set is_active = false where sku like 'DEMO-%' and is_active;

  delete from public.customers where notes = 'DEMO' and name like '%(تجريبي)';
  get diagnostics v_customers = row_count;

  delete from public.categories c
   where c.name like '%(تجريبي)'
     and not exists (select 1 from public.products p where p.category_id = c.id);

  raise notice 'حُذف % منتج تجريبي، وأُوقف % منتج مستخدم في فواتير، وحُذف % عميل تجريبي',
    v_deleted, v_disabled, v_customers;
end $$;
