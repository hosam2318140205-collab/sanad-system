-- اختبار 0018 مستندات الشراء (على قاعدة اختبار فقط): الاستلام الجزئي، المطابقة الثلاثية (سماح 2%)، ترحيل الفاتورة،
-- فرق السعر: نصيب المخزون الباقي في المتوسط ونصيب المباع فرق تكلفة، السداد النقدي/الجزئي، الإلغاء، الشراء المباشر،
-- التوافق العكسي (receive_purchase والكتابة القديمة)، المرفقات، والصلاحيات — بأرقام محسوبة يدوياً
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
create function pg_temp.as_user(p uuid) returns void language sql as $$ select set_config('request.jwt.claim.sub', p::text, true) $$;
create temp table t (k text primary key, id uuid);
grant all on t to authenticated;
create function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create function pg_temp.cost(p uuid) returns numeric language sql as $$ select cost_price from public.variant_costs where variant_id = p $$;
create function pg_temp.stock(p uuid) returns integer language sql as $$ select stock_qty from public.product_variants where id = p $$;
create function pg_temp.bal(p uuid) returns numeric language sql as $$ select coalesce((select balance from public.supplier_balances where supplier_id = p), 0) $$;
create function pg_temp.gri(p_grn text, p_variant uuid) returns uuid language sql as $$
  select id from public.goods_receipt_items where receipt_id = pg_temp.id(p_grn) and variant_id = p_variant $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000b1', 'owner@po.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000b2', 'manager@po.test', '{"role":"manager"}'),
  ('00000000-0000-0000-0000-0000000000b3', 'cashier@po.test', '{"role":"cashier"}');
insert into public.suppliers (id, name, payment_terms_days, vat_registered) values
  ('00000000-0000-0000-0000-0000000006a1', 'مصنع الثياب', 30, true),
  ('00000000-0000-0000-0000-0000000006b1', 'تاجر جملة غير مسجل', 0, false);
insert into public.products (id, name, base_price) values ('00000000-0000-0000-0000-00000000e001', 'ثوب', 100);
insert into public.product_variants (id, product_id, sku, size, stock_qty) values
  ('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000e001', 'TH-56', '56', 10),
  ('00000000-0000-0000-0000-00000000f002', '00000000-0000-0000-0000-00000000e001', 'TH-58', '58', 0);
update public.variant_costs set cost_price = 40 where variant_id = '00000000-0000-0000-0000-00000000f001';

-- ============ 1) أمر شراء بالطريقة القديمة (كتابة مباشرة) ثم اعتماده ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
insert into public.purchase_orders (id, po_no, supplier_id, status)
values ('00000000-0000-0000-0000-0000000007a1', public.next_po_no(), '00000000-0000-0000-0000-0000000006a1', 'draft');
insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-00000000f001', 20, 50),
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-00000000f002', 10, 100);
select public.approve_purchase_order('00000000-0000-0000-0000-0000000007a1');

-- ============ 2) استلام جزئي: 10 من 20 و4 من 10 ============
insert into t select 'GRN1', public.receive_goods('00000000-0000-0000-0000-0000000007a1',
  '[{"variant_id":"00000000-0000-0000-0000-00000000f001","qty":10},{"variant_id":"00000000-0000-0000-0000-00000000f002","qty":4}]',
  'الدفعة الأولى', 'a9000000-0000-0000-0000-000000000001');
insert into t select 'GRN1b', public.receive_goods('00000000-0000-0000-0000-0000000007a1',
  '[{"variant_id":"00000000-0000-0000-0000-00000000f001","qty":10}]', null, 'a9000000-0000-0000-0000-000000000001');
select pg_temp.expect_error($q$select public.receive_goods('00000000-0000-0000-0000-0000000007a1', '[{"variant_id":"00000000-0000-0000-0000-00000000f001","qty":11}]')$q$,
  '%أكبر من المتبقي%(المتبقي 10)%');
select pg_temp.expect_error($q$select public.receive_goods('00000000-0000-0000-0000-0000000007a1', '[{"variant_id":"00000000-0000-0000-0000-00000000f009","qty":1}]')$q$,
  '%لم يتم تحديد كميات%');
-- الكتابة القديمة لا تتجاوز الحماية (RLS لا يرى أمراً مستلماً جزئياً للتعديل)
update public.purchase_orders set status = 'received' where id = '00000000-0000-0000-0000-0000000007a1';
reset role;
select pg_temp.expect_error($q$update public.purchase_orders set status = 'received' where id = '00000000-0000-0000-0000-0000000007a1'$q$, '%بالاستلام فقط%');
do $$ begin
  assert pg_temp.id('GRN1') = pg_temp.id('GRN1b'), 'receipt idempotent';
  assert pg_temp.stock('00000000-0000-0000-0000-00000000f001') = 20 and pg_temp.stock('00000000-0000-0000-0000-00000000f002') = 4, 'stock received once';
  -- (10 × 40 + 10 × 50) ÷ 20 = 45
  assert pg_temp.cost('00000000-0000-0000-0000-00000000f001') = 45 and pg_temp.cost('00000000-0000-0000-0000-00000000f002') = 100, 'provisional avg cost';
  assert (select status::text from public.purchase_orders where id = '00000000-0000-0000-0000-0000000007a1') = 'partially_received', 'partially received';
  assert (select qty from public._open_po_qty() where variant_id = '00000000-0000-0000-0000-00000000f001') = 10
     and (select qty from public._open_po_qty() where variant_id = '00000000-0000-0000-0000-00000000f002') = 6, 'remaining on order';
end $$;
-- التعديل المباشر لسطر مستلم أو إلغاء أمر مستلم جزئياً: ممنوع (يُختبر كمالك الجدول لتجاوز RLS والوصول للحماية)
select pg_temp.expect_error($q$update public.purchase_items set qty = 30 where purchase_id = '00000000-0000-0000-0000-0000000007a1' and variant_id = '00000000-0000-0000-0000-00000000f001'$q$, '%استُلم منه%');
select pg_temp.expect_error($q$update public.purchase_orders set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000007a1'$q$, '%لا يمكن إلغاء%');

-- ============ 3) بيع 12 قطعة قبل وصول الفاتورة ← يبقى 8 ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select public.open_shift(0);
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000f001","qty":12}]', '[{"method":"cash","amount":1200}]');

-- ============ 4) فاتورة الدفعة الأولى: 10 × 52 (+4% خارج السماح) و4 × 101 (+1% ضمن السماح) ============
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
insert into t select 'INV1', public.save_supplier_invoice(null, '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000007a1',
  'INV-A1', current_date, null, 'credit',
  jsonb_build_array(
    jsonb_build_object('receipt_item_id', pg_temp.gri('GRN1', '00000000-0000-0000-0000-00000000f001'), 'qty', 10, 'unit_cost', 52),
    jsonb_build_object('receipt_item_id', pg_temp.gri('GRN1', '00000000-0000-0000-0000-00000000f002'), 'qty', 4, 'unit_cost', 101)),
  null, 'a9000000-0000-0000-0000-000000000002');
do $$ declare r record; begin
  -- 520 + 404 = 924، ضريبة 78 + 60.60 = 138.60، الإجمالي 1062.60، الاستحقاق بعد 30 يوماً
  select * into r from public.supplier_invoices where id = pg_temp.id('INV1');
  assert r.subtotal = 924 and r.vat_amount = 138.60 and r.total = 1062.60 and r.due_date = current_date + 30, format('invoice totals %s', row_to_json(r));
  select * into r from public.match_invoice(pg_temp.id('INV1')) where sku = 'TH-56';
  assert r.result = 'price_over_tolerance' and r.diff_pct = 4, format('TH-56 match %s', row_to_json(r));
  select * into r from public.match_invoice(pg_temp.id('INV1')) where sku = 'TH-58';
  assert r.result = 'within_tolerance' and r.diff_pct = 1, 'TH-58 within tolerance';
end $$;
-- رقم فاتورة المورد لا يتكرر (بعد إزالة المسافات وتوحيد الحروف)
select pg_temp.expect_error(format($q$select public.save_supplier_invoice(null, '00000000-0000-0000-0000-0000000006a1', null, ' inv-a1 ', current_date, null, 'credit', '[{"receipt_item_id":"%s","qty":1}]')$q$,
  pg_temp.gri('GRN1', '00000000-0000-0000-0000-00000000f001')), '%supplier_invoices_no_key%');
select pg_temp.expect_error(format($q$select public.post_supplier_invoice('%s')$q$, pg_temp.id('INV1')), '%خارج نسبة السماح%');
-- رفع السماح إلى 5% من الإعدادات يجعلها ضمن السماح (ثم نعيده 2%)
reset role;
update public.store_settings set purchase_match_tolerance_pct = 5 where id = 1;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
do $$ begin
  assert (select result from public.match_invoice(pg_temp.id('INV1')) where sku = 'TH-56') = 'within_tolerance', 'tolerance is configurable';
end $$;
reset role;
update public.store_settings set purchase_match_tolerance_pct = 2, inventory_segregation = true where id = 1;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_error(format($q$select public.post_supplier_invoice('%s', 'السعر ارتفع')$q$, pg_temp.id('INV1')), '%فصل المهام%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.post_supplier_invoice(pg_temp.id('INV1'), 'ارتفاع سعر القماش — موافق عليه');
select public.post_supplier_invoice(pg_temp.id('INV1'), 'مرة ثانية');
reset role;
update public.store_settings set inventory_segregation = false where id = 1;
set constraints all immediate;
do $$ declare c record; begin
  assert (select status from public.supplier_invoices where id = pg_temp.id('INV1')) = 'posted'
     and (select match_status from public.supplier_invoices where id = pg_temp.id('INV1')) = 'override', 'posted with override';
  assert (select count(*) from public.supplier_ledger where source_id = pg_temp.id('INV1')) = 1, 'double post = one ledger entry';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000006a1') = 1062.60, 'liability created at posting';
  -- TH-56: فرق 10 × 2 = 20. الباقي 8 من 10 ← 16 للمخزون: (8 × 45 + 16) ÷ 8 = 47، و4 فرق تكلفة
  select * into c from public.cost_adjustments where source_id = pg_temp.id('INV1') and variant_id = '00000000-0000-0000-0000-00000000f001';
  assert c.total_delta = 20 and c.qty_in_stock = 8 and c.stock_delta = 16 and c.variance_delta = 4 and c.cost_before = 45 and c.cost_after = 47,
    format('TH-56 adjustment %s', row_to_json(c));
  assert pg_temp.cost('00000000-0000-0000-0000-00000000f001') = 47, 'avg cost 47';
  -- TH-58: فرق 4 × 1 = 4، الأربع قطع موجودة ← 101 بلا فرق تكلفة
  assert pg_temp.cost('00000000-0000-0000-0000-00000000f002') = 101, 'avg cost 101';
  assert (select qty_invoiced from public.purchase_items where purchase_id = '00000000-0000-0000-0000-0000000007a1'
           and variant_id = '00000000-0000-0000-0000-00000000f001') = 10, 'PO line invoiced 10';
end $$;
set constraints all deferred;

-- المفوتر أكثر من المستلم: ممنوع دائماً
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
insert into t select 'INVX', public.save_supplier_invoice(null, '00000000-0000-0000-0000-0000000006a1', null, 'INV-X', current_date, null, 'credit',
  jsonb_build_array(jsonb_build_object('receipt_item_id', pg_temp.gri('GRN1', '00000000-0000-0000-0000-00000000f001'), 'qty', 1, 'unit_cost', 50)));
select pg_temp.expect_error(format($q$select public.post_supplier_invoice('%s', 'تجاوز')$q$, pg_temp.id('INVX')), '%أكبر من المستلم%');
select public.void_supplier_invoice(pg_temp.id('INVX'), 'مسودة خاطئة');

-- ============ 5) استلام الباقي + فاتورة نقدية مطابقة تُسدَّد عند الترحيل ============
insert into t select 'GRN2', public.receive_goods('00000000-0000-0000-0000-0000000007a1', null, 'الباقي');
insert into t select 'INV2', public.save_supplier_invoice(null, '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000007a1',
  'INV-A2', current_date, null, 'cash',
  (select jsonb_agg(jsonb_build_object('receipt_item_id', id, 'qty', qty)) from public.goods_receipt_items where receipt_id = pg_temp.id('GRN2')));
select public.post_supplier_invoice(pg_temp.id('INV2'), null, '{"method":"cash"}');
reset role;
set constraints all immediate;
do $$ begin
  assert (select status::text from public.purchase_orders where id = '00000000-0000-0000-0000-0000000007a1') = 'received', 'PO fully received';
  -- (10 × 50 + 6 × 100) × 1.15 = 1265، مدفوعة بالكامل
  assert (select total from public.supplier_invoices where id = pg_temp.id('INV2')) = 1265
     and (select status from public.supplier_invoices where id = pg_temp.id('INV2')) = 'paid'
     and (select match_status from public.supplier_invoices where id = pg_temp.id('INV2')) = 'matched', 'cash invoice paid and matched';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000006a1') = 1062.60, 'cash invoice nets to zero';
  assert not exists (select 1 from public._open_po_qty() where variant_id in ('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000f002')),
    'nothing left on order';
end $$;
set constraints all deferred;

-- ============ 6) إلغاء فاتورة الدفعة الأولى: عكس القيد والكميات وتعديل التكلفة، وإعادة استخدام رقمها ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_error(format($q$select public.void_supplier_invoice('%s', 'x')$q$, pg_temp.id('INV2')), '%سداد%');
select public.void_supplier_invoice(pg_temp.id('INV1'), 'فاتورة معدّلة من المورد');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.bal('00000000-0000-0000-0000-0000000006a1') = 0, 'void reverses liability';
  assert (select qty_invoiced from public.goods_receipt_items where id = pg_temp.gri('GRN1', '00000000-0000-0000-0000-00000000f001')) = 0, 'receipt line uninvoiced';
  assert exists (select 1 from public.cost_adjustments where source_type = 'invoice_void' and source_id = pg_temp.id('INV1')
                   and variant_id = '00000000-0000-0000-0000-00000000f001' and total_delta = -20), 'cost adjustment reversed';
end $$;
set constraints all deferred;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
insert into t select 'INV1R', public.save_supplier_invoice(null, '00000000-0000-0000-0000-0000000006a1', null, 'INV-A1', current_date, null, 'credit',
  jsonb_build_array(jsonb_build_object('receipt_item_id', pg_temp.gri('GRN1', '00000000-0000-0000-0000-00000000f001'), 'qty', 10, 'unit_cost', 50)));
select public.post_supplier_invoice(pg_temp.id('INV1R'));

-- ============ 7) التوافق العكسي: أمر شراء قديم + receive_purchase ============
insert into public.purchase_orders (id, po_no, supplier_id, status)
values ('00000000-0000-0000-0000-0000000007b1', public.next_po_no(), '00000000-0000-0000-0000-0000000006a1', 'ordered');
insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost) values
  ('00000000-0000-0000-0000-0000000007b1', '00000000-0000-0000-0000-00000000f002', 5, 100);
select public.receive_purchase('00000000-0000-0000-0000-0000000007b1');
select pg_temp.expect_error($q$select public.receive_purchase('00000000-0000-0000-0000-0000000007b1')$q$, '%بحالة received%');
-- أمر قديم لم يُستلم يُلغى بالكتابة المباشرة كما كان
insert into public.purchase_orders (id, po_no, supplier_id, status)
values ('00000000-0000-0000-0000-0000000007c1', public.next_po_no(), '00000000-0000-0000-0000-0000000006a1', 'ordered');
update public.purchase_orders set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000007c1';
reset role;
do $$ begin
  assert (select status::text from public.purchase_orders where id = '00000000-0000-0000-0000-0000000007b1') = 'received'
     and (select qty_received from public.purchase_items where purchase_id = '00000000-0000-0000-0000-0000000007b1') = 5
     and exists (select 1 from public.goods_receipts where purchase_order_id = '00000000-0000-0000-0000-0000000007b1'), 'legacy receive creates GRN';
  assert (select status::text from public.purchase_orders where id = '00000000-0000-0000-0000-0000000007c1') = 'cancelled', 'legacy cancel still works';
end $$;

-- ============ 8) شراء مباشر من مورد غير مسجل ضريبياً إلى فرع، مع دفعة جزئية ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
insert into public.locations (code, name, kind) values ('BR9', 'فرع الاختبار', 'store');
select public.set_staff_location('00000000-0000-0000-0000-0000000000b3', (select id from public.locations where code = 'BR9'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_error($q$select public.create_direct_purchase('00000000-0000-0000-0000-0000000006b1', (select id from public.locations where code = 'BR9'), '[{"variant_id":"00000000-0000-0000-0000-00000000f002","qty":3,"unit_cost":90}]', 'W-1', current_date, 'partial', '{"amount":270,"method":"cash"}')$q$,
  '%أقل من إجمالي%');
insert into t select 'DIR', public.create_direct_purchase('00000000-0000-0000-0000-0000000006b1', (select id from public.locations where code = 'BR9'),
  '[{"variant_id":"00000000-0000-0000-0000-00000000f002","qty":3,"unit_cost":90}]', 'W-1', current_date, 'partial',
  '{"amount":100,"method":"cash"}', null, 'a9000000-0000-0000-0000-000000000003');
insert into t select 'DIR2', public.create_direct_purchase('00000000-0000-0000-0000-0000000006b1', (select id from public.locations where code = 'BR9'),
  '[{"variant_id":"00000000-0000-0000-0000-00000000f002","qty":3,"unit_cost":90}]', 'W-1', current_date, 'partial',
  '{"amount":100,"method":"cash"}', null, 'a9000000-0000-0000-0000-000000000003');
reset role;
set constraints all immediate;
do $$ declare i record; begin
  assert pg_temp.id('DIR') = pg_temp.id('DIR2'), 'direct purchase idempotent';
  select * into i from public.supplier_invoices where id = pg_temp.id('DIR');
  -- 3 × 90 = 270 بلا ضريبة، مدفوع 100
  assert i.total = 270 and i.vat_amount = 0 and i.settled_amount = 100 and i.status = 'partially_paid', format('direct invoice %s', row_to_json(i));
  assert pg_temp.bal('00000000-0000-0000-0000-0000000006b1') = 170, 'supplier B owes 170';
  assert (select qty from public.location_stock where location_id = (select id from public.locations where code = 'BR9')
           and variant_id = '00000000-0000-0000-0000-00000000f002') = 3, 'stock received at branch';
end $$;
set constraints all deferred;

-- ============ 9) الاستلام من موظف الموقع فقط، والمرفقات، والصلاحيات ============
insert into public.purchase_orders (id, po_no, supplier_id, status, location_id)
values ('00000000-0000-0000-0000-0000000007d1', 'PO-T-D1', '00000000-0000-0000-0000-0000000006a1', 'ordered', (select id from public.locations where code = 'MAIN')),
       ('00000000-0000-0000-0000-0000000007e1', 'PO-T-E1', '00000000-0000-0000-0000-0000000006a1', 'ordered', (select id from public.locations where code = 'BR9'));
insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost) values
  ('00000000-0000-0000-0000-0000000007d1', '00000000-0000-0000-0000-00000000f002', 2, 100),
  ('00000000-0000-0000-0000-0000000007e1', '00000000-0000-0000-0000-00000000f002', 2, 100);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
-- الوردية المفتوحة تحدد موقع الموظف (#8): أُغلقت وردية الرئيسي فصار موقعه الفرع المعيّن
select public.close_shift((select id from public.shifts where cashier_id = '00000000-0000-0000-0000-0000000000b3' and status = 'open'), 1200);
select pg_temp.expect_error($q$select public.receive_goods('00000000-0000-0000-0000-0000000007d1')$q$, '%موقع الاستلام%');
select public.receive_goods('00000000-0000-0000-0000-0000000007e1');
select pg_temp.expect_error($q$select * from public.match_invoice(gen_random_uuid())$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.approve_purchase_order('00000000-0000-0000-0000-0000000007d1')$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.add_purchase_attachment('supplier_invoice', gen_random_uuid(), 'x', 'a.pdf', 'application/pdf', 10)$q$, 'غير مصرح');
do $$ begin
  assert (select count(*) from public.goods_receipts) = 0 and (select count(*) from public.cost_adjustments) = 0, 'cashier sees no purchasing docs';
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_error(format($q$select public.add_purchase_attachment('supplier_invoice', '%s', 'supplier_invoice/other/a.pdf', 'a.pdf', 'application/pdf', 100)$q$, pg_temp.id('INV2')), '%لا يطابق%');
select pg_temp.expect_error(format($q$select public.add_purchase_attachment('supplier_invoice', '%1$s', 'supplier_invoice/%1$s/a.exe', 'a.exe', 'application/x-msdownload', 100)$q$, pg_temp.id('INV2')), '%غير مسموح%');
select public.add_purchase_attachment('supplier_invoice', pg_temp.id('INV2'), 'supplier_invoice/' || pg_temp.id('INV2') || '/scan.pdf', 'scan.pdf', 'application/pdf', 250000);
do $$ declare v record; begin
  select * into v from public.cost_variance_summary(current_date, current_date) where source_type = 'invoice_price';
  assert v.variance_delta = 4, format('cost variance recorded on posting date: %s', row_to_json(v));
  assert (select count(*) from public.purchase_attachments) = 1, 'attachment registered';
end $$;
reset role;

set constraints all immediate;
do $$ begin
  assert not exists (select 1 from public.product_variants v
                      where v.stock_qty <> coalesce((select sum(qty) from public.location_stock s where s.variant_id = v.id), 0)), 'location invariant (#8)';
end $$;
rollback;
