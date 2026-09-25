-- اختبار Smart Inventory 2.0 (على قاعدة اختبار فقط)
-- المواقع والقيد الإلزامي، التحويل الكامل/الجزئي/الفروقات/فصل المهام، منع البيع من فرع بلا مخزون،
-- الجرد (مسح مكرر، جهازان، بيع أثناء الجرد، جرد أعمى)، مركز القرار (النقل قبل الشراء) بأرقام محسوبة يدوياً،
-- المقاسات الناقصة، الشاذ، الراكد، والصلاحيات
\set ON_ERROR_STOP 1
begin;

create function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like p_like then
      raise exception 'unexpected error "%" (expected like "%") for: %', sqlerrm, p_like, p_sql;
    end if;
    return;
  end;
  raise exception 'expected error like "%" but succeeded: %', p_like, p_sql;
end $$;
create temp table t (k text primary key, id uuid);
grant all on t to authenticated;
create function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create function pg_temp.loc(p_code text) returns uuid language sql as $$ select id from public.locations where code = p_code $$;
create function pg_temp.qty(p_code text, p_variant uuid) returns integer language sql as $$
  select coalesce((select qty from public.location_stock where location_id = pg_temp.loc(p_code) and variant_id = p_variant), 0) $$;
create function pg_temp.total(p_variant uuid) returns integer language sql as $$
  select stock_qty from public.product_variants where id = p_variant $$;
-- القيد: فحص فوري لكل الأصناف
create function pg_temp.invariant_ok() returns boolean language sql as $$
  select not exists (select 1 from public.product_variants v
                      where v.stock_qty <> coalesce((select sum(qty) from public.location_stock s where s.variant_id = v.id), 0)) $$;
create function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, true) $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000f1', 'owner@inv.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000f2', 'manager@inv.test', '{"role":"manager"}'),
  ('00000000-0000-0000-0000-0000000000f3', 'cashA@inv.test', '{"role":"cashier"}'),
  ('00000000-0000-0000-0000-0000000000f4', 'cashB@inv.test', '{"role":"cashier"}');

insert into public.categories (id, name) values ('00000000-0000-0000-0000-00000000c001', 'رجالي');
insert into public.products (id, name, base_price, category_id) values
  ('00000000-0000-0000-0000-00000000a001', 'قميص', 100, '00000000-0000-0000-0000-00000000c001'),
  ('00000000-0000-0000-0000-00000000a002', 'حذاء', 200, '00000000-0000-0000-0000-00000000c001'),
  ('00000000-0000-0000-0000-00000000a003', 'بنطلون', 150, '00000000-0000-0000-0000-00000000c001');
insert into public.product_variants (id, product_id, sku, barcode, size, color, stock_qty) values
  ('00000000-0000-0000-0000-00000000b001', '00000000-0000-0000-0000-00000000a001', 'SH-M-K', '2000000000011', 'M', 'أسود', 10),
  ('00000000-0000-0000-0000-00000000b002', '00000000-0000-0000-0000-00000000a001', 'SH-L-K', '2000000000028', 'L', 'أسود', 3),
  ('00000000-0000-0000-0000-00000000b003', '00000000-0000-0000-0000-00000000a001', 'SH-XL-K', '2000000000035', 'XL', 'أسود', 5),
  ('00000000-0000-0000-0000-00000000b009', '00000000-0000-0000-0000-00000000a001', 'SH-M-W', '2000000000097', 'M', 'أبيض', 1),
  ('00000000-0000-0000-0000-00000000b004', '00000000-0000-0000-0000-00000000a003', 'PN-30', null, '30', 'كحلي', 4),
  ('00000000-0000-0000-0000-00000000b005', '00000000-0000-0000-0000-00000000a002', 'SHO-42', '2000000000059', '42', 'بني', 24),
  ('00000000-0000-0000-0000-00000000b006', '00000000-0000-0000-0000-00000000a002', 'SHO-43', '2000000000066', '43', 'بني', 9),
  ('00000000-0000-0000-0000-00000000b007', '00000000-0000-0000-0000-00000000a003', 'PN-32', '2000000000073', '32', 'كحلي', 15),
  ('00000000-0000-0000-0000-00000000b008', '00000000-0000-0000-0000-00000000a003', 'PN-34', '2000000000080', '34', 'كحلي', 6);
update public.variant_costs set cost_price = 50 where variant_id <> '00000000-0000-0000-0000-00000000b004';
update public.variant_costs set cost_price = 150 where variant_id = '00000000-0000-0000-0000-00000000b002';

-- ============ 1) الرصيد الافتتاحي في الرئيسي والقيد ============
set constraints all immediate;
do $$ begin
  assert pg_temp.qty('MAIN', '00000000-0000-0000-0000-00000000b001') = 10 and pg_temp.invariant_ok(), 'opening at MAIN';
  assert (select count(*) from public.locations where kind = 'transit') = 1, 'transit exists';
end $$;
-- أي كتابة تكسر القيد تُرفض عند نهاية المعاملة
select pg_temp.expect_error($q$update public.location_stock set qty = qty + 1 where variant_id = '00000000-0000-0000-0000-00000000b001'; set constraints all immediate$q$,
  '%تعارض مخزون%');
set constraints all deferred;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
insert into public.locations (code, name, kind) values ('BR2', 'فرع العليا', 'store'), ('WH1', 'المستودع', 'warehouse');
select public.set_staff_location('00000000-0000-0000-0000-0000000000f3', pg_temp.loc('MAIN'));
select public.set_staff_location('00000000-0000-0000-0000-0000000000f4', pg_temp.loc('BR2'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select pg_temp.expect_error($q$insert into public.locations (code, name) values ('X1', 'x')$q$, '%row-level security%');
select pg_temp.expect_error($q$select public.set_staff_location('00000000-0000-0000-0000-0000000000f3', pg_temp.loc('BR2'))$q$, 'غير مصرح');

-- ============ 2) التحويل الكامل: طلب ← اعتماد ← شحن جزئي ← استلام بنقص ← وصول متأخر ============
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
insert into t select 'T1', public.request_transfer(pg_temp.loc('MAIN'), pg_temp.loc('BR2'),
  '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":5}]', 'تعزيز الفرع', 'e0000000-0000-0000-0000-000000000001');
insert into t select 'T1b', public.request_transfer(pg_temp.loc('MAIN'), pg_temp.loc('BR2'),
  '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":5}]', 'تعزيز الفرع', 'e0000000-0000-0000-0000-000000000001');
do $$ begin
  assert pg_temp.id('T1') = pg_temp.id('T1b'), 'request idempotent';
  assert (select transfer_no from public.transfers where id = pg_temp.id('T1')) like 'TRF-%', 'transfer number';
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select pg_temp.expect_error($q$select public.request_transfer(pg_temp.loc('BR2'), pg_temp.loc('WH1'), '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":1}]')$q$, '%فرعه فقط%');
select pg_temp.expect_error($q$select public.approve_transfer((select id from t where k = 'T1'))$q$, 'غير مصرح');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select public.approve_transfer(pg_temp.id('T1'));
-- المعتمد يحجز من المتاح: 10 − 5 = 5 فقط لتحويل آخر
insert into t select 'T0', public.request_transfer(pg_temp.loc('MAIN'), pg_temp.loc('WH1'),
  '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":6}]');
select pg_temp.expect_error($q$select public.approve_transfer((select id from t where k = 'T0'))$q$, '%المتاح في المصدر%هو 5%');
select public.close_transfer(pg_temp.id('T0'), 'تجربة', true);

-- الشحن من موظف موقع المصدر فقط
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
select pg_temp.expect_error($q$select public.ship_transfer((select id from t where k = 'T1'), '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":3}]')$q$, '%موظفي موقع المصدر%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select public.ship_transfer(pg_temp.id('T1'), '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":3}]', false, 'e0000000-0000-0000-0000-00000000005a');
select public.ship_transfer(pg_temp.id('T1'), '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":3}]', false, 'e0000000-0000-0000-0000-00000000005a');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.qty('MAIN', '00000000-0000-0000-0000-00000000b001') = 7 and pg_temp.qty('TRANSIT', '00000000-0000-0000-0000-00000000b001') = 3,
    format('partial ship once: MAIN %s TRANSIT %s', pg_temp.qty('MAIN', '00000000-0000-0000-0000-00000000b001'), pg_temp.qty('TRANSIT', '00000000-0000-0000-0000-00000000b001'));
  assert pg_temp.total('00000000-0000-0000-0000-00000000b001') = 10 and pg_temp.invariant_ok(), 'transfer does not change total';
  assert (select status from public.transfers where id = pg_temp.id('T1')) = 'in_transit', 'in transit';
end $$;
set constraints all deferred;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select public.ship_transfer(pg_temp.id('T1'), null, false, 'e0000000-0000-0000-0000-00000000005b');
-- الاستلام: من موظف موقع الوجهة فقط، 4 من 5 مع إنهاء ← فرق معلق
select pg_temp.expect_error($q$select public.receive_transfer((select id from t where k = 'T1'))$q$, '%موظفي موقع الوجهة%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
select public.receive_transfer(pg_temp.id('T1'), '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":4}]', true, 'e0000000-0000-0000-0000-0000000000a1');
select public.receive_transfer(pg_temp.id('T1'), '[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":4}]', true, 'e0000000-0000-0000-0000-0000000000a1');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.qty('BR2', '00000000-0000-0000-0000-00000000b001') = 4 and pg_temp.qty('TRANSIT', '00000000-0000-0000-0000-00000000b001') = 1,
    'received 4 once, 1 pending in transit';
  assert (select status from public.transfers where id = pg_temp.id('T1')) = 'short_received', 'short received';
  assert (select discrepancy_by from public.transfer_items where transfer_id = pg_temp.id('T1')) = '00000000-0000-0000-0000-0000000000f4', 'discrepancy by receiver';
  assert pg_temp.total('00000000-0000-0000-0000-00000000b001') = 10 and pg_temp.invariant_ok(), 'shortage is not a loss yet';
end $$;
set constraints all deferred;
set local role authenticated;
-- الكاشير لا يعتمد الفقد؛ وصول الكمية المتبقية لاحقاً يكمل التحويل
select pg_temp.expect_error($q$select public.resolve_transfer_loss((select id from t where k = 'T1'), '00000000-0000-0000-0000-00000000b001', 1, 'ضاع')$q$, 'غير مصرح');
select public.receive_transfer(pg_temp.id('T1'), null, true, 'e0000000-0000-0000-0000-0000000000a2');
-- استلام مكرر بعد الاكتمال مرفوض ولا يضيف شيئاً
select pg_temp.expect_error($q$select public.receive_transfer((select id from t where k = 'T1'))$q$, '%لا توجد كمية بانتظار الاستلام%');
reset role;
set constraints all immediate;
do $$ begin
  assert (select status from public.transfers where id = pg_temp.id('T1')) = 'completed', 'completed after late arrival';
  assert pg_temp.qty('BR2', '00000000-0000-0000-0000-00000000b001') = 5 and pg_temp.qty('TRANSIT', '00000000-0000-0000-0000-00000000b001') = 0, 'all arrived';
  assert (select string_agg(event, ',' order by id) from public.transfer_events where transfer_id = pg_temp.id('T1'))
         = 'request,approve,ship,ship,receive,finalize,receive,finalize',
         'timeline: ' || (select string_agg(event, ',' order by id) from public.transfer_events where transfer_id = pg_temp.id('T1'));
  assert pg_temp.invariant_ok(), 'invariant after transfer';
end $$;
set constraints all deferred;

-- ============ 3) فصل المهام + اعتماد الفقد ============
update public.store_settings set inventory_segregation = true where id = 1;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
insert into t select 'T2', public.request_transfer(pg_temp.loc('MAIN'), pg_temp.loc('BR2'), '[{"variant_id":"00000000-0000-0000-0000-00000000b003","qty":2}]');
select pg_temp.expect_error($q$select public.approve_transfer((select id from t where k = 'T2'))$q$, '%فصل المهام%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select public.approve_transfer(pg_temp.id('T2'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select public.ship_transfer(pg_temp.id('T2'));
select public.receive_transfer(pg_temp.id('T2'), '[{"variant_id":"00000000-0000-0000-0000-00000000b003","qty":1}]', true);
select pg_temp.expect_error($q$select public.resolve_transfer_loss((select id from t where k = 'T2'), '00000000-0000-0000-0000-00000000b003', 1, 'فقد')$q$, '%فصل المهام%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select pg_temp.expect_error($q$select public.resolve_transfer_loss((select id from t where k = 'T2'), '00000000-0000-0000-0000-00000000b003', 1, ' ')$q$, '%سبب%');
select pg_temp.expect_error($q$select public.resolve_transfer_loss((select id from t where k = 'T2'), '00000000-0000-0000-0000-00000000b003', 2, 'فقد')$q$, '%أكبر من الفرق%');
select public.resolve_transfer_loss(pg_temp.id('T2'), '00000000-0000-0000-0000-00000000b003', 1, 'تلف أثناء النقل');
reset role;
set constraints all immediate;
do $$ begin
  assert (select status from public.transfers where id = pg_temp.id('T2')) = 'completed', 'loss closes transfer';
  assert pg_temp.total('00000000-0000-0000-0000-00000000b003') = 4 and pg_temp.qty('TRANSIT', '00000000-0000-0000-0000-00000000b003') = 0, 'loss reduces total from transit';
  assert exists (select 1 from public.location_movements where type = 'transit_loss' and transfer_id is null and qty_change = -1
                   and variant_id = '00000000-0000-0000-0000-00000000b003'), 'transit loss movement';
  assert pg_temp.invariant_ok(), 'invariant after loss';
end $$;
set constraints all deferred;
update public.store_settings set inventory_segregation = false where id = 1;

-- الإلغاء: صاحب الطلب فقط (أو المدير)
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
insert into t select 'T3', public.request_transfer(pg_temp.loc('MAIN'), pg_temp.loc('BR2'), '[{"variant_id":"00000000-0000-0000-0000-00000000b002","qty":1}]');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select pg_temp.expect_error($q$select public.close_transfer((select id from t where k = 'T3'), 'لا')$q$, '%لا يمكن إلغاء%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
select public.close_transfer(pg_temp.id('T3'), 'لم نعد نحتاجه');

-- ============ 4) البيع من فرع لا يملك كمية محلية ============
select public.open_shift(0);
-- الفرع فيه قطعة XL واحدة (من T2): بيعها مسموح
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000b003","qty":1}]', '[{"method":"cash","amount":100}]');
-- L غير موجود في الفرع (3 في الرئيسي): مرفوض مع توجيه
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000b002","qty":1}]', '[{"method":"cash","amount":100}]')$q$,
  '%غير متوفر في هذا الفرع (فرع العليا)%متوفر 3 قطع في%');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.qty('BR2', '00000000-0000-0000-0000-00000000b003') = 0 and pg_temp.total('00000000-0000-0000-0000-00000000b003') = 3, 'branch sale attributed';
  assert pg_temp.invariant_ok(), 'invariant after branch sale';
end $$;
set constraints all deferred;

-- ============ 5) الجرد الذكي في الرئيسي ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
insert into t select 'C1', public.start_location_count(pg_temp.loc('MAIN'), null, 'جرد شهري');
select pg_temp.expect_error($q$select public.start_location_count(pg_temp.loc('MAIN'))$q$, '%يوجد جرد مفتوح%');
select pg_temp.expect_error($q$select public.start_stock_count(null, 'قديم')$q$, '%تعدد المواقع%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select public.open_shift(0);
-- M أسود: اللقطة 5 (بعد تحويل 5). بيع قطعة قبل عدّها ← 4 على الرف
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":1}]', '[{"method":"cash","amount":100}]');
-- الكاشير: مسحتان + إعادة إرسال نفس المسحة (لا تُحسب)
select public.record_count_scan(pg_temp.id('C1'), '2000000000011', 1, 'e0000000-0000-0000-0000-0000000000c1');
select public.record_count_scan(pg_temp.id('C1'), '2000000000011', 1, 'e0000000-0000-0000-0000-0000000000c2');
select public.record_count_scan(pg_temp.id('C1'), '2000000000011', 1, 'e0000000-0000-0000-0000-0000000000c1');
-- جهاز ثانٍ (المدير) يمسح نفس SKU مرتين: تُجمع مع مسحات الكاشير
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select public.record_count_scan(pg_temp.id('C1'), 'sh-m-k', 1, 'e0000000-0000-0000-0000-0000000000c3');
select public.record_count_scan(pg_temp.id('C1'), 'SH-M-K', 1, 'e0000000-0000-0000-0000-0000000000c4');
-- L أسود: اللقطة 3، المعدود 1
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select public.record_count_scan(pg_temp.id('C1'), 'SH-L-K', 1, 'e0000000-0000-0000-0000-0000000000c5');
-- بعد عدّ M: بيع قطعة أخرى (يجب ألا يظهر فرقاً)
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000b001","qty":1}]', '[{"method":"cash","amount":100}]');
-- جرد أعمى: الكاشير لا يرى النظامي، ولا يعدّل الكمية مباشرة
select pg_temp.expect_error($q$select expected_qty from public.stock_count_items limit 1$q$, '%permission denied%');
select pg_temp.expect_error($q$update public.stock_count_items set counted_qty = 99 where count_id = (select id from t where k = 'C1')$q$, '%بالمسح%');
select pg_temp.expect_error($q$select * from public.count_review((select id from t where k = 'C1'))$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.approve_count((select id from t where k = 'C1'))$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.record_count_scan((select id from t where k = 'C1'), 'NOPE')$q$, '%لا يوجد صنف%');
select public.submit_count(pg_temp.id('C1'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
do $$ declare r record; begin
  select * into r from public.count_review(pg_temp.id('C1')) where sku = 'SH-M-K';
  -- اللقطة 5 + حركة −1 قبل العدّ = 4 نظامي، والمعدود 4 (2 + 2) ← لا فرق رغم البيع أثناء الجرد
  assert r.snapshot_qty = 5 and r.moves_after_snapshot = -1 and r.expected_qty = 4 and r.counted_qty = 4 and r.variance = 0,
    format('M: snap %s moves %s expected %s counted %s', r.snapshot_qty, r.moves_after_snapshot, r.expected_qty, r.counted_qty);
  select * into r from public.count_review(pg_temp.id('C1')) where sku = 'SH-L-K';
  assert r.expected_qty = 3 and r.counted_qty = 1 and r.variance = -2 and r.variance_value = -300, 'L variance −2 × 150';
end $$;
do $$ begin
  assert public.approve_count(pg_temp.id('C1')) = 1, 'one adjustment';
end $$;
reset role;
set constraints all immediate;
do $$ begin
  -- M: 5 − 1 − 1 (مبيعات) = 3 بلا تسوية | L: 3 − 2 = 1
  assert pg_temp.qty('MAIN', '00000000-0000-0000-0000-00000000b001') = 3, 'M untouched by count';
  assert pg_temp.qty('MAIN', '00000000-0000-0000-0000-00000000b002') = 1 and pg_temp.total('00000000-0000-0000-0000-00000000b002') = 1, 'L adjusted −2';
  assert (select count(*) from public.stock_count_scans where count_id = pg_temp.id('C1')) = 5, 'five scans recorded (duplicate ignored)';
  assert pg_temp.invariant_ok(), 'invariant after count';
end $$;
set constraints all deferred;

-- تسوية موقع: لا نزول تحت الصفر، ومرة واحدة لنفس المفتاح
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select pg_temp.expect_error($q$select public.adjust_location_stock(pg_temp.loc('MAIN'), '00000000-0000-0000-0000-00000000b002', -2, 'تلف')$q$, '%سالباً%');
select public.adjust_location_stock(pg_temp.loc('MAIN'), '00000000-0000-0000-0000-00000000b002', 2, 'مرتجع مورد', 'e0000000-0000-0000-0000-0000000000d1');
select public.adjust_location_stock(pg_temp.loc('MAIN'), '00000000-0000-0000-0000-00000000b002', 2, 'مرتجع مورد', 'e0000000-0000-0000-0000-0000000000d1');
reset role;
do $$ begin
  assert pg_temp.qty('MAIN', '00000000-0000-0000-0000-00000000b002') = 3 and pg_temp.total('00000000-0000-0000-0000-00000000b002') = 3, 'adjust once';
end $$;

-- ============ 6) مركز القرار: مثال المالك ============
-- الأحذية 42: الرئيسي 12 وباع 1 خلال 60 يوماً، الفرع 2 وباع 9 خلال 30 يوماً
-- 43: نفد في كل مكان والفرع باع 9 ← شراء | بنطلون 32: الرئيسي فائضه 2 فقط ← نقل 2 + شراء 4 | بنطلون 34 في المستودع منذ 200 يوم ← تخفيض
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
insert into t select 'T4', public.request_transfer(pg_temp.loc('MAIN'), pg_temp.loc('BR2'),
  '[{"variant_id":"00000000-0000-0000-0000-00000000b005","qty":11},{"variant_id":"00000000-0000-0000-0000-00000000b006","qty":9},{"variant_id":"00000000-0000-0000-0000-00000000b007","qty":11}]');
select public.approve_transfer(pg_temp.id('T4'));
select public.ship_transfer(pg_temp.id('T4'));
insert into t select 'T5', public.request_transfer(pg_temp.loc('MAIN'), pg_temp.loc('WH1'), '[{"variant_id":"00000000-0000-0000-0000-00000000b008","qty":6}]');
select public.approve_transfer(pg_temp.id('T5'));
select public.ship_transfer(pg_temp.id('T5'));
select public.receive_transfer(pg_temp.id('T5'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f4');
select public.receive_transfer(pg_temp.id('T4'));
insert into t select 'SB', public.complete_sale(
  '[{"variant_id":"00000000-0000-0000-0000-00000000b005","qty":9},{"variant_id":"00000000-0000-0000-0000-00000000b006","qty":9},{"variant_id":"00000000-0000-0000-0000-00000000b007","qty":9}]',
  '[{"method":"card","amount":4950}]');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
insert into t select 'SA', public.complete_sale(
  '[{"variant_id":"00000000-0000-0000-0000-00000000b005","qty":1},{"variant_id":"00000000-0000-0000-0000-00000000b007","qty":1}]',
  '[{"method":"cash","amount":350}]');
reset role;
update public.sales set created_at = now() - interval '20 days' where id = pg_temp.id('SB');
update public.sales set created_at = now() - interval '50 days' where id = pg_temp.id('SA');
update public.product_variants set created_at = now() - interval '120 days';
update public.locations set created_at = now() - interval '120 days';
update public.location_movements set created_at = now() - interval '200 days'
 where location_id = pg_temp.loc('WH1') and variant_id = '00000000-0000-0000-0000-00000000b008';
update public.location_movements set created_at = now() - interval '120 days'
 where location_id = pg_temp.loc('MAIN') and type = 'opening';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
create temp table dc as select * from public.decision_center(7, 30, 7);
grant select on dc to authenticated;
do $$ declare r record; begin
  -- الفرع: متوسط = 0.5×9/30 + 0.3×9/90 = 0.180 ← نقطة الطلب ⌈2.52⌉=3، المستهدف ⌈7.92⌉=8، المتاح 2 ← يحتاج 6
  -- الرئيسي: متوسط = 0.3×1/90 = 0.003 ← مستهدفه ⌈0.132⌉=1، المتاح 12 ← فائض 11 ← نقل 6، ولا شراء
  select * into r from dc where action = 'transfer' and sku = 'SHO-42';
  assert r.qty = 6 and r.from_name = (select name from public.locations where code = 'MAIN') and r.to_name = 'فرع العليا',
    format('SHO-42 transfer %s', r.qty);
  assert r.reason like '%لديه 12 قطعة%فائض 11%لديه 2 قطعة وباع 9 خلال 30 يوماً%يحتاج 6%انقل 6 قطعة%', r.reason;
  assert (r.why -> 'to' ->> 'need')::int = 6 and (r.why -> 'from' ->> 'surplus')::int = 11, 'why numbers';
  assert not exists (select 1 from dc where action = 'order' and sku = 'SHO-42'), 'no purchase when transferable';
  -- 43: لا فائض في أي موقع ← شراء 8
  select * into r from dc where action = 'order' and sku = 'SHO-43';
  assert r.qty = 8 and r.cost_value = 400 and r.retail_value = 1600, format('SHO-43 order %s', r.qty);
  -- بنطلون 32: الرئيسي 3 ومستهدفه 1 ← فائض 2 ← نقل 2 ثم شراء 4
  assert (select qty from dc where action = 'transfer' and sku = 'PN-32') = 2, 'PN-32 transfer 2';
  select * into r from dc where action = 'order' and sku = 'PN-32';
  assert r.qty = 4 and r.reason like '%يُغطّى 2 بالنقل%اشترِ 4%', r.reason;
  -- بنطلون 34 في المستودع 200 يوم ولا يحتاجه أحد ← تخفيض (اقتراح فقط)
  select * into r from dc where action = 'markdown' and sku = 'PN-34';
  assert r.qty = 6 and r.from_name = 'المستودع' and r.reason like '%لا يُطبَّق أي خصم تلقائياً%', 'PN-34 markdown';
  assert exists (select 1 from dc where action = 'review' and sku = 'PN-30'), 'review: missing cost';
end $$;

-- تنفيذ توصية النقل: تحويل معتمد، ولا يُقترح مرة أخرى، ولا يتكرر بنفس المفتاح
create temp table tr as select public.create_transfers_from_decisions(
  jsonb_build_array(jsonb_build_object('from', pg_temp.loc('MAIN'), 'to', pg_temp.loc('BR2'),
                                       'variant_id', '00000000-0000-0000-0000-00000000b005', 'qty', 6)),
  null, 'e0000000-0000-0000-0000-0000000000e1') as res;
grant select on tr to authenticated;
do $$ declare v_again jsonb; begin
  assert (select res -> 0 ->> 'status' from tr) = 'approved', 'decision transfer approved';
  v_again := public.create_transfers_from_decisions(
    jsonb_build_array(jsonb_build_object('from', pg_temp.loc('MAIN'), 'to', pg_temp.loc('BR2'),
                                         'variant_id', '00000000-0000-0000-0000-00000000b005', 'qty', 6)),
    null, 'e0000000-0000-0000-0000-0000000000e1');
  assert v_again -> 0 ->> 'id' = (select res -> 0 ->> 'id' from tr), 'same client ref, same transfer';
  assert not exists (select 1 from public.decision_center(7, 30, 7) where action = 'transfer' and sku = 'SHO-42'), 'no repeat suggestion';
end $$;

-- التوفر: المتاح = الموجود − المحجوز − الصادر المعتمد
do $$ declare a record; begin
  select * into a from public.location_availability(pg_temp.loc('MAIN')) where sku = 'SHO-42';
  assert a.on_hand = 12 and a.outgoing = 6 and a.available = 6 and a.reserved = 0, format('availability %s/%s/%s', a.on_hand, a.outgoing, a.available);
  select * into a from public.location_availability(pg_temp.loc('BR2')) where sku = 'SHO-42';
  assert a.incoming_approved = 6 and a.in_transit = 0, 'incoming approved';
end $$;

-- ============ 7) المقاسات الناقصة، الشاذ، الراكد ============
do $$ begin
  -- القميص: M/L/XL × أسود/أبيض ← L أبيض و XL أبيض غير مُنشأة
  assert exists (select 1 from public.size_color_gaps(null) where gap_kind = 'not_created' and product_name = 'قميص' and size = 'L' and color = 'أبيض'), 'gap not_created';
  -- الفرع باع XL ونفد منه، متوفر 3 في الرئيسي ← «انقل قبل أن تشتري»
  assert exists (select 1 from public.size_color_gaps(pg_temp.loc('BR2')) where gap_kind = 'out_of_stock' and size = 'XL'
                   and available_elsewhere = 3 and reason like '%انقل قبل أن تشتري%'), 'gap out_of_stock with transfer hint';
  assert exists (select 1 from public.inventory_anomalies() where kind = 'missing_cost' and sku = 'PN-30'), 'missing cost';
  assert exists (select 1 from public.inventory_anomalies() where kind = 'missing_barcode' and sku = 'PN-30'), 'missing barcode';
  assert exists (select 1 from public.inventory_anomalies() where kind = 'count_variance' and sku = 'SH-L-K'), 'count variance (value 300)';
  assert exists (select 1 from public.dead_stock_plan(pg_temp.loc('WH1')) where sku = 'PN-34' and bucket = 180 and action = 'markdown'), 'dead 180';
end $$;

-- مسودة شراء بموقع الاستلام
insert into public.suppliers (id, name) values ('00000000-0000-0000-0000-00000000d001', 'مورد الأحذية');
do $$ declare v uuid; begin
  v := public.create_purchase_draft_at('00000000-0000-0000-0000-00000000d001', pg_temp.loc('BR2'),
         '[{"variant_id":"00000000-0000-0000-0000-00000000b006","qty":8}]');
  assert (select location_id from public.purchase_orders where id = v) = pg_temp.loc('BR2'), 'draft at branch';
end $$;

-- ============ 8) الصلاحيات ============
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f3');
select pg_temp.expect_error($q$select * from public.decision_center()$q$, 'غير مصرح');
select pg_temp.expect_error($q$select * from public.location_availability()$q$, 'غير مصرح');
select pg_temp.expect_error($q$select * from public.inventory_anomalies()$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.adjust_location_stock(pg_temp.loc('MAIN'), '00000000-0000-0000-0000-00000000b001', 1, 'x')$q$, 'غير مصرح');
select pg_temp.expect_error($q$insert into public.location_stock (location_id, variant_id, qty) values (pg_temp.loc('MAIN'), '00000000-0000-0000-0000-00000000b001', 1)$q$, '%permission denied%');
select pg_temp.expect_error($q$insert into public.transfers (from_location, to_location) values (pg_temp.loc('MAIN'), pg_temp.loc('BR2'))$q$, '%permission denied%');
do $$ begin
  -- الكاشير يرى تحويلات فرعه فقط، ولا يرى سجل حركات المواقع
  assert not exists (select 1 from public.transfers where pg_temp.loc('MAIN') not in (from_location, to_location)), 'cashier sees own transfers';
  assert (select count(*) from public.location_movements) = 0, 'cashier cannot read movements';
  assert (public.pos_location_context() ->> 'multi')::boolean and (public.pos_location_context() ->> 'location_id')::uuid = pg_temp.loc('MAIN'), 'pos context';
  assert (select on_hand from public.variant_locations('00000000-0000-0000-0000-00000000b005') where location_name = 'فرع العليا') = 2, 'variant locations';
end $$;
reset role;

set constraints all immediate;
do $$ begin
  assert pg_temp.invariant_ok(), 'final invariant';
  assert (select coalesce(sum(qty), 0) from public.location_stock where location_id = pg_temp.loc('TRANSIT')) = 0, 'nothing stuck in transit';
end $$;

rollback;
