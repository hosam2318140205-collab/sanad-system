-- اختبار ملفات البيانات التجريبية والتصفير (على قاعدة اختبار فقط)
\set ON_ERROR_STOP 1
begin;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'owner@demo.test');
-- منتج وعميل "حقيقيان" يجب ألا يُمسّا
insert into public.products (id, name, base_price) values ('00000000-0000-0000-0000-0000000000b1', 'منتج حقيقي', 50);
insert into public.product_variants (product_id, sku, stock_qty) values ('00000000-0000-0000-0000-0000000000b1', 'REAL-1', 3);
insert into public.customers (name, phone) values ('عميل حقيقي', '0555555555');

\i supabase/setup/02_demo_data.sql
\i supabase/setup/02_demo_data.sql

do $$ begin
  assert (select count(*) from public.product_variants where sku like 'DEMO-%') = 10, 'demo variants seeded once';
  assert (select count(*) from public.products where name like '%تجريبي') = 3, 'demo products';
  assert (select count(*) from public.stock_movements m join public.product_variants v on v.id = m.variant_id where v.sku like 'DEMO-%') = 10, 'opening movements';
end $$;

-- بيع صنف تجريبي كمالك
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select public.complete_sale(
  jsonb_build_array(jsonb_build_object('variant_id', (select id from public.product_variants where sku = 'DEMO-SHMG-RED'), 'qty', 1)),
  '[{"method":"cash","amount":95}]'::jsonb);
reset role;

\i supabase/setup/03_remove_demo_data.sql
\i supabase/setup/03_remove_demo_data.sql

do $$ begin
  assert (select count(*) from public.product_variants where sku like 'DEMO-%') = 1, 'only the sold demo variant remains';
  assert not (select is_active from public.products where name = 'شماغ تجريبي'), 'sold demo product deactivated';
  assert (select count(*) from public.sales) = 1, 'sale kept';
  assert (select count(*) from public.customers where notes = 'DEMO') = 0, 'demo customer removed';
  assert (select count(*) from public.categories where name like '%(تجريبي)') = 1, 'only category of kept product remains';
  assert exists (select 1 from public.product_variants where sku = 'REAL-1'), 'real product untouched';
  assert exists (select 1 from public.customers where name = 'عميل حقيقي'), 'real customer untouched';
end $$;

-- التصفير يرفض بدون تأكيد
savepoint before_reset;
\echo (expected: the reset below must refuse without confirmation)
\set ON_ERROR_STOP 0
\i supabase/setup/04_reset_test_transactions.sql
\set ON_ERROR_STOP 1
rollback to savepoint before_reset;
do $$ begin assert (select count(*) from public.sales) = 1, 'reset without confirmation must not delete'; end $$;

select set_config('pos.confirm_reset', 'DELETE-ALL-TRANSACTIONS', false);
\i supabase/setup/04_reset_test_transactions.sql
\i supabase/setup/03_remove_demo_data.sql

do $$ begin
  assert (select count(*) from public.sales) = 0, 'sales cleared';
  assert (select count(*) from public.product_variants where sku like 'DEMO-%') = 0, 'demo fully removed after reset';
  assert (select count(*) from public.categories where name like '%(تجريبي)') = 0, 'demo categories removed';
  assert (select last_value from public.invoice_seq) = 1 and not (select is_called from public.invoice_seq), 'invoice numbering restarts at 1';
  assert (select stock_qty from public.product_variants where sku = 'REAL-1') = 3, 'real stock kept';
  assert (select count(*) from public.stock_movements where note like 'رصيد افتتاحي بعد%') = 1, 'opening balance recorded';
  assert coalesce(current_setting('pos.confirm_reset', true), '') = '', 'confirmation cleared after reset';
end $$;

rollback;
