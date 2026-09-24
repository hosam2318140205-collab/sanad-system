-- اختبار دخاني شامل لسيناريوهات النظام تحت RLS
-- التشغيل: psql -v ON_ERROR_STOP=1 -f supabase/tests/smoke_test.sql  (على قاعدة بيانات اختبار فقط)
\set ON_ERROR_STOP 1
begin;

-- المستخدمون: الأول يصبح المالك تلقائياً
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.sa', '{"full_name":"المالك"}');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-000000000002', 'cashier@test.sa', '{"role":"cashier"}');
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000003', 'stranger@test.sa');

do $$ begin
  assert (select role from public.profiles where email = 'owner@test.sa') = 'owner', 'first user must be owner';
  assert (select is_active from public.profiles where email = 'stranger@test.sa') = false, 'self signup must be inactive';
end $$;

-- GoTrue Admin API: ينشئ المستخدم ثم يحدّث app_metadata بطلب لاحق
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000004', 'manager@test.sa');
update auth.users set raw_app_meta_data = '{"role":"manager","provider":"email"}'
 where id = '00000000-0000-0000-0000-000000000004';
do $$ begin
  assert (select role = 'manager' and is_active from public.profiles where email = 'manager@test.sa'), 'role synced from app_metadata update';
end $$;

-- ===================== المالك =====================
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

update public.store_settings set store_name = 'بوتيك الاختبار', vat_number = '300000000000003';
insert into public.categories (id, name) values ('10000000-0000-0000-0000-000000000001', 'ثياب');
insert into public.products (id, name, category_id, base_price)
values ('20000000-0000-0000-0000-000000000001', 'ثوب سعودي كلاسيك', '10000000-0000-0000-0000-000000000001', 115);
insert into public.product_variants (id, product_id, sku, barcode, size, color, stock_qty) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'THB-52-W', '2000000000015', '52', 'أبيض', 5),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'THB-54-W', '2000000000022', '54', 'أبيض', 0);
update public.variant_costs set cost_price = 50 where variant_id = '30000000-0000-0000-0000-000000000001';

-- تعديل المخزون المباشر ممنوع
do $$ begin
  begin
    update public.product_variants set stock_qty = 100 where sku = 'THB-52-W';
    raise exception 'direct stock update should fail';
  exception when others then
    if sqlerrm = 'direct stock update should fail' then raise; end if;
  end;
end $$;

-- مورد + أمر شراء + استلام
insert into public.suppliers (id, name) values ('40000000-0000-0000-0000-000000000001', 'مصنع الأقمشة');
insert into public.purchase_orders (id, po_no, supplier_id)
values ('50000000-0000-0000-0000-000000000001', public.next_po_no(), '40000000-0000-0000-0000-000000000001');
insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost) values
  ('50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 5, 60),
  ('50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 10, 60);
select public.receive_purchase('50000000-0000-0000-0000-000000000001');

do $$ begin
  assert (select total from public.purchase_orders where id = '50000000-0000-0000-0000-000000000001') = 1035, 'po total';
  assert (select stock_qty from public.product_variants where sku = 'THB-52-W') = 10, 'stock after purchase';
  assert (select cost_price from public.variant_costs where variant_id = '30000000-0000-0000-0000-000000000001') = 55, 'weighted cost';
end $$;

-- ===================== الكاشير =====================
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);

do $$ begin
  assert (select count(*) from public.variant_costs) = 0, 'cashier must not see costs';
  assert (select count(*) from public.suppliers) = 0, 'cashier must not see suppliers';
end $$;

-- الكاشير لا يستطيع ترقية نفسه
do $$ begin
  begin
    update public.profiles set role = 'owner' where id = auth.uid();
    raise exception 'cashier escalated role';
  exception when others then
    if sqlerrm = 'cashier escalated role' then raise; end if;
  end;
end $$;

insert into public.customers (id, name, phone) values ('60000000-0000-0000-0000-000000000001', 'عبدالله', '0500000000');

-- بيع: 2 × 115 مع خصم فاتورة 10 → الإجمالي 220 شامل الضريبة
create temp table t_sale as
select public.complete_sale(
  '[{"variant_id":"30000000-0000-0000-0000-000000000001","qty":2,"discount":0},
    {"variant_id":"30000000-0000-0000-0000-000000000002","qty":1,"discount":5}]'::jsonb,
  '[{"method":"card","amount":200},{"method":"cash","amount":150}]'::jsonb,
  '60000000-0000-0000-0000-000000000001', 10, null) as id;

do $$
declare s public.sales;
begin
  select * into s from public.sales where id = (select id from t_sale);
  assert s.total = 330, format('total %s', s.total);
  assert s.vat_amount = 43.05, format('vat %s', s.vat_amount);
  assert s.change_amount = 20, format('change %s', s.change_amount);
  assert (select sum(line_total) from public.sale_items where sale_id = s.id) = s.total, 'lines sum';
  assert (select stock_qty from public.product_variants where sku = 'THB-52-W') = 8, 'stock after sale';
end $$;

-- الكاشير لا يستطيع قراءة عمود التكلفة
do $$ begin
  begin
    perform unit_cost from public.sale_items limit 1;
    raise exception 'cashier read unit_cost';
  exception when insufficient_privilege then null;
  end;
end $$;

-- خصم أكبر من المسموح للكاشير
do $$ begin
  begin
    perform public.complete_sale('[{"variant_id":"30000000-0000-0000-0000-000000000001","qty":1,"discount":50}]',
      '[{"method":"cash","amount":200}]');
    raise exception 'discount limit not enforced';
  exception when others then
    if sqlerrm = 'discount limit not enforced' then raise; end if;
  end;
end $$;

-- استبدال: إرجاع قطعة كرصيد ثم استخدامه في فاتورة جديدة
create temp table t_ret as
select public.process_return(
  (select id from t_sale),
  jsonb_build_array(jsonb_build_object(
    'sale_item_id', (select id from public.sale_items where sale_id = (select id from t_sale) and sku = 'THB-52-W'),
    'qty', 1, 'restock', true)),
  'exchange', 'مقاس غير مناسب') as id;

do $$ begin
  assert (select status from public.sales where id = (select id from t_sale)) = 'partially_returned', 'status';
  assert (select stock_qty from public.product_variants where sku = 'THB-52-W') = 9, 'restock';
end $$;

select public.complete_sale(
  '[{"variant_id":"30000000-0000-0000-0000-000000000002","qty":1}]'::jsonb,
  jsonb_build_array(
    jsonb_build_object('method', 'exchange_credit', 'return_id', (select id from t_ret),
                       'amount', (select total from public.returns where id = (select id from t_ret))),
    jsonb_build_object('method', 'cash', 'amount', 50)));

-- إعادة استخدام الرصيد ممنوعة
do $$ begin
  begin
    perform public.complete_sale('[{"variant_id":"30000000-0000-0000-0000-000000000002","qty":1}]',
      jsonb_build_array(jsonb_build_object('method', 'exchange_credit', 'return_id', (select id from t_ret),
        'amount', (select total from public.returns where id = (select id from t_ret)))));
    raise exception 'credit reused';
  exception when others then
    if sqlerrm = 'credit reused' then raise; end if;
  end;
end $$;

-- الكاشير لا يستطيع التقارير
do $$ begin
  begin
    perform public.dashboard_stats();
    raise exception 'cashier accessed dashboard';
  exception when others then
    if sqlerrm = 'cashier accessed dashboard' then raise; end if;
  end;
end $$;

-- ===================== المالك: جرد وتقارير =====================
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

create temp table t_cnt as select public.start_stock_count(null, 'جرد شهري') as id;
update public.stock_count_items set counted_qty = 7
 where count_id = (select id from t_cnt)
   and variant_id = '30000000-0000-0000-0000-000000000001';
select public.apply_stock_count((select id from t_cnt));

do $$
declare d jsonb; r jsonb;
begin
  assert (select stock_qty from public.product_variants where sku = 'THB-52-W') = 7, 'count applied';
  d := public.dashboard_stats();
  r := public.sales_report(current_date - 1, current_date + 1);
  assert (d -> 'today' ->> 'count')::int = 2, format('dashboard count %s', d -> 'today');
  assert (r -> 'summary' ->> 'invoices')::int = 2, 'report invoices';
  assert (r -> 'summary' ->> 'returns_count')::int = 1, 'report returns';
  assert (select count(*) from public.audit_log) > 5, 'audit log written';
  raise notice 'dashboard: %', d -> 'today';
  raise notice 'report: %', r -> 'summary';
end $$;

rollback;
