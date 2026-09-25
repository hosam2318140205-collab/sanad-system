-- اختبار مساعد الشراء الذكي (على قاعدة اختبار فقط)
-- الأرقام المتوقعة محسوبة يدوياً من المعادلات الموثقة في 0008_purchase_advisor.sql
\set ON_ERROR_STOP 1
begin;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000aa001', 'owner@adv.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000aa002', 'cashier@adv.test', '{"role":"cashier"}');

insert into public.suppliers (id, name) values ('00000000-0000-0000-0000-0000000ab001', 'مورد الأحذية');
insert into public.products (id, name, base_price) values
  ('00000000-0000-0000-0000-0000000ac001', 'حذاء', 200),
  ('00000000-0000-0000-0000-0000000ac002', 'حزام', 80),
  ('00000000-0000-0000-0000-0000000ac003', 'قبعة', 50);
-- A1 / A2: عمرهما 100 يوم. B1: راكد لم يُبع أبداً. C1: أُضيف قبل 5 أيام.
insert into public.product_variants (id, product_id, sku, size, color, stock_qty) values
  ('00000000-0000-0000-0000-0000000ad001', '00000000-0000-0000-0000-0000000ac001', 'ADV-A1', '42', 'أسود', 20),
  ('00000000-0000-0000-0000-0000000ad002', '00000000-0000-0000-0000-0000000ac001', 'ADV-A2', '43', 'أسود', 3),
  ('00000000-0000-0000-0000-0000000ad003', '00000000-0000-0000-0000-0000000ac002', 'ADV-B1', null, 'بني', 10),
  ('00000000-0000-0000-0000-0000000ad004', '00000000-0000-0000-0000-0000000ac003', 'ADV-C1', null, null, 10);
insert into public.variant_costs (variant_id, cost_price) values
  ('00000000-0000-0000-0000-0000000ad001', 90), ('00000000-0000-0000-0000-0000000ad002', 90),
  ('00000000-0000-0000-0000-0000000ad003', 30), ('00000000-0000-0000-0000-0000000ad004', 20)
on conflict (variant_id) do update set cost_price = excluded.cost_price;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000aa001', true);
select public.open_shift(0);

-- A1: 6 قبل 60 يوماً، 4 قبل 20 يوماً، 2 اليوم (ومرتجع 1 اليوم). A2: 2 اليوم. C1: 5 اليوم.
create temp table t_sales (tag text, id uuid);
grant all on t_sales to authenticated;
insert into t_sales select 'a1_60', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000ad001","qty":6}]', '[{"method":"cash","amount":1200}]');
insert into t_sales select 'a1_20', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000ad001","qty":4}]', '[{"method":"cash","amount":800}]');
insert into t_sales select 'a1_0', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000ad001","qty":2}]', '[{"method":"cash","amount":400}]');
insert into t_sales select 'a2_0', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000ad002","qty":2}]', '[{"method":"cash","amount":400}]');
insert into t_sales select 'c1_0', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000ad004","qty":5}]', '[{"method":"cash","amount":250}]');
select public.process_return(
  (select id from t_sales where tag = 'a1_0'),
  jsonb_build_array(jsonb_build_object('sale_item_id',
    (select id from public.sale_items where sale_id = (select id from t_sales where tag = 'a1_0')), 'qty', 1)),
  'cash', 'مقاس');

-- تأريخ البيانات للماضي (كمسؤول قاعدة البيانات)
reset role;
update public.sales set created_at = now() - interval '60 days' where id = (select id from t_sales where tag = 'a1_60');
update public.sales set created_at = now() - interval '20 days' where id = (select id from t_sales where tag = 'a1_20');
update public.product_variants set created_at = now() - interval '100 days'
 where id in ('00000000-0000-0000-0000-0000000ad001', '00000000-0000-0000-0000-0000000ad002', '00000000-0000-0000-0000-0000000ad003');
update public.product_variants set created_at = now() - interval '5 days' where id = '00000000-0000-0000-0000-0000000ad004';
update public.stock_movements set created_at = now() - interval '100 days'
 where variant_id = '00000000-0000-0000-0000-0000000ad003' and type = 'opening';
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000aa001', true);

create temp table t_adv as select * from public.purchase_advisor(7, 30, 7);
grant all on t_adv to authenticated;

do $$
declare r record;
begin
  -- A1: صافي 7=1، 30=5، 90=11؛ المتوسط = 0.2×1/7 + 0.5×5/30 + 0.3×11/90 = 0.149
  select * into r from t_adv where sku = 'ADV-A1';
  assert r.stock = 9, 'A1 stock ' || r.stock;
  assert (r.sold_7, r.sold_30, r.sold_90) = (1, 5, 11), format('A1 sold %s/%s/%s', r.sold_7, r.sold_30, r.sold_90);
  assert r.avg_daily = 0.149, 'A1 avg ' || r.avg_daily;
  assert r.reorder_point = 3 and r.target_qty = 7, format('A1 rop %s target %s', r.reorder_point, r.target_qty);
  assert r.cover_days = 60.4, 'A1 cover ' || r.cover_days;
  assert r.suggested_qty = 0, 'A1 above reorder point → no order';
  assert r.idle_days = 0, 'A1 sold today';

  -- A2: 2 اليوم؛ المتوسط = 0.2×2/7 + 0.5×2/30 + 0.3×2/90 = 0.097؛ نقطة الطلب ⌈1.358⌉=2؛ المستهدف ⌈4.268⌉=5
  select * into r from t_adv where sku = 'ADV-A2';
  assert r.stock = 1 and r.avg_daily = 0.097, format('A2 stock %s avg %s', r.stock, r.avg_daily);
  assert r.reorder_point = 2 and r.target_qty = 5, format('A2 rop %s target %s', r.reorder_point, r.target_qty);
  assert r.suggested_qty = 4, 'A2 suggested ' || r.suggested_qty;
  assert r.unit_cost = 90 and r.unit_price = 200, 'A2 cost/price';

  -- C1: عمره 5 أيام → كل النوافذ تُقسم على 5 → المتوسط 1.0 (لا يُظلم الصنف الجديد)
  select * into r from t_adv where sku = 'ADV-C1';
  assert r.age_days = 5 and r.avg_daily = 1.000, format('C1 age %s avg %s', r.age_days, r.avg_daily);
  assert r.reorder_point = 14 and r.target_qty = 44 and r.suggested_qty = 39, format('C1 %s/%s/%s', r.reorder_point, r.target_qty, r.suggested_qty);

  -- B1: لم يُبع — راكد منذ دخوله المخزون قبل 100 يوم، ولا توصية شراء
  select * into r from t_adv where sku = 'ADV-B1';
  assert r.avg_daily = 0 and r.cover_days is null and r.suggested_qty = 0, 'B1 no sales';
  assert r.idle_days = 100 and r.last_sale_at is null, 'B1 idle ' || r.idle_days;
end $$;

-- إعدادات مختلفة: مدة توريد 14 وتغطية 60 يوماً ترفعان نقطة الطلب والمستهدف
do $$
declare r record;
begin
  select * into r from public.purchase_advisor(14, 60, 7) where sku = 'ADV-A2';
  -- ⌈0.097×21⌉=3 ، ⌈0.097×81⌉=8 → 8−1 = 7
  assert r.reorder_point = 3 and r.target_qty = 8 and r.suggested_qty = 7, format('A2 custom %s/%s/%s', r.reorder_point, r.target_qty, r.suggested_qty);
end $$;

-- قيم غير صحيحة مرفوضة
do $$ begin
  begin
    perform * from public.purchase_advisor(7, 0, 7);
    raise exception 'cover 0 allowed';
  exception when others then
    if sqlerrm = 'cover 0 allowed' then raise; end if;
  end;
end $$;

-- تحويل التوصية إلى مسودة: كمية غير صحيحة مرفوضة
do $$ begin
  begin
    perform public.create_purchase_draft('00000000-0000-0000-0000-0000000ab001',
      '[{"variant_id":"00000000-0000-0000-0000-0000000ad002","qty":0}]');
    raise exception 'qty 0 allowed';
  exception when others then
    if sqlerrm = 'qty 0 allowed' then raise; end if;
  end;
end $$;

create temp table t_po as select public.create_purchase_draft('00000000-0000-0000-0000-0000000ab001',
  '[{"variant_id":"00000000-0000-0000-0000-0000000ad002","qty":4},{"variant_id":"00000000-0000-0000-0000-0000000ad004","qty":39}]') as id;
grant all on t_po to authenticated;

do $$
declare po public.purchase_orders;
begin
  select * into po from public.purchase_orders where id = (select id from t_po);
  assert po.status = 'draft' and po.supplier_id = '00000000-0000-0000-0000-0000000ab001', 'draft for supplier';
  assert po.po_no like 'PO-%', 'po number';
  assert (select count(*) from public.purchase_items where purchase_id = po.id) = 2, 'two lines';
  assert (select unit_cost from public.purchase_items where purchase_id = po.id and variant_id = '00000000-0000-0000-0000-0000000ad002') = 90, 'cost from variant_costs';
  -- 4×90 + 39×20 = 1140 قبل الضريبة (يحسبه trigger الإجماليات)
  assert po.subtotal = 1140, 'subtotal ' || po.subtotal;
  -- لا يغيّر المخزون (مسودة فقط)
  assert (select stock_qty from public.product_variants where id = '00000000-0000-0000-0000-0000000ad002') = 1, 'stock untouched';
end $$;

-- بعد المسودة: الكمية المفتوحة تُخصم ولا تتكرر التوصية، والمورد الأخير معروف
do $$
declare r record;
begin
  select * into r from public.purchase_advisor(7, 30, 7) where sku = 'ADV-A2';
  assert r.on_order = 4 and r.suggested_qty = 0, format('A2 after draft on_order %s suggested %s', r.on_order, r.suggested_qty);
  assert r.supplier_name = 'مورد الأحذية', 'last supplier';
  select * into r from public.purchase_advisor(7, 30, 7) where sku = 'ADV-C1';
  assert r.on_order = 39 and r.suggested_qty = 0, 'C1 covered by draft';
end $$;

-- الكاشير ممنوع (التكلفة ضمن النتائج)
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000aa002', true);
do $$ begin
  begin
    perform * from public.purchase_advisor();
    raise exception 'cashier allowed';
  exception when others then
    if sqlerrm = 'cashier allowed' then raise; end if;
    assert sqlerrm = 'غير مصرح', sqlerrm;
  end;
  begin
    perform public.create_purchase_draft('00000000-0000-0000-0000-0000000ab001',
      '[{"variant_id":"00000000-0000-0000-0000-0000000ad002","qty":1}]');
    raise exception 'cashier draft allowed';
  exception when others then
    if sqlerrm = 'cashier draft allowed' then raise; end if;
  end;
end $$;

-- الزائر غير المسجل لا يملك صلاحية التنفيذ
reset role;
set local role anon;
do $$ begin
  begin
    perform * from public.purchase_advisor();
    raise exception 'anon allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
