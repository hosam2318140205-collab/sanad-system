-- اختبار 0019 (على قاعدة اختبار فقط): تكاليف الوصول (بالقيمة/الكمية/يدوي وتقريب يطابق حرفياً)، إشعار تخفيض السعر
-- (نصيب المخزون في المتوسط والمباع فرق تكلفة)، المرتجع للمورد (فصل المهام، لا أكثر من الموجود، شحن مرة واحدة)،
-- إشعار المرتجع، الخصم غير المطبق، الاسترداد، الإلغاءات، والصلاحيات — بأرقام محسوبة يدوياً
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
create function pg_temp.gri(p_variant uuid) returns uuid language sql as $$
  select gi.id from public.goods_receipt_items gi where gi.receipt_id = pg_temp.id('GRN') and gi.variant_id = p_variant $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000d1', 'owner@rt.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000d2', 'manager@rt.test', '{"role":"manager"}'),
  ('00000000-0000-0000-0000-0000000000d3', 'cashier@rt.test', '{"role":"cashier"}');
insert into public.suppliers (id, name, payment_terms_days, vat_registered) values
  ('00000000-0000-0000-0000-0000000009a1', 'مصنع الثياب', 60, true),
  ('00000000-0000-0000-0000-0000000009b1', 'شركة الشحن', 15, true),
  ('00000000-0000-0000-0000-0000000009c1', 'الجمارك', 0, false);
insert into public.products (id, name, base_price) values ('00000000-0000-0000-0000-00000000e101', 'ثوب', 200);
insert into public.product_variants (id, product_id, sku, size) values
  ('00000000-0000-0000-0000-00000000f101', '00000000-0000-0000-0000-00000000e101', 'TR-56', '56'),
  ('00000000-0000-0000-0000-00000000f102', '00000000-0000-0000-0000-00000000e101', 'TR-58', '58');

-- أمر شراء: 10 × 100 و20 × 50، استلام كامل، فاتورة مطابقة آجلة = 2000 + 300 ضريبة = 2300
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
insert into public.purchase_orders (id, po_no, supplier_id, status)
values ('00000000-0000-0000-0000-000000000aa1', public.next_po_no(), '00000000-0000-0000-0000-0000000009a1', 'ordered');
insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost) values
  ('00000000-0000-0000-0000-000000000aa1', '00000000-0000-0000-0000-00000000f101', 10, 100),
  ('00000000-0000-0000-0000-000000000aa1', '00000000-0000-0000-0000-00000000f102', 20, 50);
insert into t select 'GRN', public.receive_goods('00000000-0000-0000-0000-000000000aa1');
insert into t select 'INV', public.save_supplier_invoice(null, '00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-000000000aa1',
  'F-100', current_date, null, 'credit',
  (select jsonb_agg(jsonb_build_object('receipt_item_id', id, 'qty', qty)) from public.goods_receipt_items where receipt_id = pg_temp.id('GRN')));
select public.post_supplier_invoice(pg_temp.id('INV'));

-- ============ 1) تكاليف الوصول ============
do $$ declare r record; v_sum numeric; begin
  -- بالكمية (معاينة): 400 على 10 و20 ← 133.33 و266.67 (آخر سطر يأخذ فرق التقريب)
  select sum(amount) into v_sum from public.landed_cost_preview(array[pg_temp.id('GRN')], 400, 'qty');
  assert v_sum = 400, 'qty preview sums exactly';
  select * into r from public.landed_cost_preview(array[pg_temp.id('GRN')], 400, 'qty') where sku = 'TR-56';
  assert r.amount = 133.33, format('qty share %s', r.amount);
  -- 100 على ثلاثة أسطر متساوية: 33.33 + 33.33 + 33.34
end $$;
select pg_temp.expect_error(format($q$select public.post_landed_cost(array['%s'::uuid], '[{"cost_type":"freight","amount":300,"supplier_id":"00000000-0000-0000-0000-0000000009b1"}]', 'manual', '[{"receipt_item_id":"%s","amount":100}]')$q$,
  pg_temp.id('GRN'), pg_temp.gri('00000000-0000-0000-0000-00000000f101')), '%لا يساوي إجمالي%');
select pg_temp.expect_error(format($q$select public.post_landed_cost(array['%s'::uuid], '[{"cost_type":"freight","amount":300}]', 'value')$q$, pg_temp.id('GRN')), '%مورداً%');
-- بالقيمة: شحن 300 (+45 ضريبة) وجمارك 100 (بلا ضريبة) = 400 على قيمتين متساويتين 1000 و1000 ← 200 لكل صنف
insert into t select 'LCV', public.post_landed_cost(array[pg_temp.id('GRN')],
  '[{"cost_type":"freight","description":"شحن بحري","amount":300,"supplier_id":"00000000-0000-0000-0000-0000000009b1","supplier_invoice_no":"SH-9"},
    {"cost_type":"customs","description":"رسوم جمركية","amount":100,"supplier_id":"00000000-0000-0000-0000-0000000009c1"}]',
  'value', null, 'شحنة سبتمبر', 'ab000000-0000-0000-0000-000000000001');
insert into t select 'LCV2', public.post_landed_cost(array[pg_temp.id('GRN')], '[{"cost_type":"freight","amount":300,"supplier_id":"00000000-0000-0000-0000-0000000009b1"}]',
  'value', null, null, 'ab000000-0000-0000-0000-000000000001');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.id('LCV') = pg_temp.id('LCV2'), 'landed cost idempotent';
  -- 100 + 200/10 = 120 و50 + 200/20 = 60 (لا ضريبة في التكلفة)
  assert pg_temp.cost('00000000-0000-0000-0000-00000000f101') = 120 and pg_temp.cost('00000000-0000-0000-0000-00000000f102') = 60, 'landed cost into avg';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000009b1') = 345 and pg_temp.bal('00000000-0000-0000-0000-0000000009c1') = 100, 'freight 345, customs 100 payable';
  assert (select due_date from public.supplier_invoices where supplier_id = '00000000-0000-0000-0000-0000000009b1') = current_date + 15, 'expense invoice uses supplier terms';
  assert (select sum(amount) from public.landed_cost_allocations where voucher_id = pg_temp.id('LCV')) = 400, 'allocations = total';
end $$;
set constraints all deferred;

-- ============ 2) بيع 4 من TR-56 ثم إشعار تخفيض سعر 10 للقطعة على 10 قطع ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d3');
select public.open_shift(0);
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000f101","qty":4}]', '[{"method":"cash","amount":800}]');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
insert into t select 'CNP', public.post_credit_note('00000000-0000-0000-0000-0000000009a1', 'price', null, pg_temp.id('INV'), 'CR-1', current_date,
  jsonb_build_array(jsonb_build_object('receipt_item_id', pg_temp.gri('00000000-0000-0000-0000-00000000f101'), 'qty', 10, 'unit_amount', 10)));
reset role;
set constraints all immediate;
do $$ declare c record; begin
  -- 100 تخفيض: الباقي 6 من 10 ← 60 من المتوسط: (6 × 120 − 60) ÷ 6 = 110، و−40 فرق تكلفة (مكسب)
  select * into c from public.cost_adjustments where source_id = pg_temp.id('CNP');
  assert c.total_delta = -100 and c.stock_delta = -60 and c.variance_delta = -40 and c.cost_after = 110, format('price credit %s', row_to_json(c));
  -- 100 + 15 ضريبة = 115، مطبّق على الفاتورة المرتبطة
  assert (select total from public.supplier_credit_notes where id = pg_temp.id('CNP')) = 115
     and (select allocated_amount from public.supplier_credit_notes where id = pg_temp.id('CNP')) = 115, 'credit applied to its invoice';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000009a1') = 2185 and (select settled_amount from public.supplier_invoices where id = pg_temp.id('INV')) = 115, 'balance 2185';
end $$;
set constraints all deferred;

-- ============ 3) مرتجع 3 × TR-58: فصل المهام، الشحن، ولا أكثر من الموجود ============
update public.store_settings set inventory_segregation = true where id = 1;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
insert into t select 'RT', public.create_supplier_return('00000000-0000-0000-0000-0000000009a1', (select id from public.locations where code = 'MAIN'),
  jsonb_build_array(jsonb_build_object('receipt_item_id', pg_temp.gri('00000000-0000-0000-0000-00000000f102'), 'qty', 3)), 'عيب خياطة', null,
  'ab000000-0000-0000-0000-000000000002');
select pg_temp.expect_error(format($q$select public.ship_supplier_return('%s')$q$, pg_temp.id('RT')), '%غير معتمد%');
select pg_temp.expect_error(format($q$select public.approve_supplier_return('%s')$q$, pg_temp.id('RT')), '%فصل المهام%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.approve_supplier_return(pg_temp.id('RT'));
-- الكاشير في موقع المرتجع يشحنه (الكمية فقط)
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d3');
select public.ship_supplier_return(pg_temp.id('RT'));
select public.ship_supplier_return(pg_temp.id('RT'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
insert into t select 'RT2', public.create_supplier_return('00000000-0000-0000-0000-0000000009a1', (select id from public.locations where code = 'MAIN'),
  '[{"variant_id":"00000000-0000-0000-0000-00000000f102","qty":18}]', 'تجربة');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.approve_supplier_return(pg_temp.id('RT2'));
select pg_temp.expect_error(format($q$select public.ship_supplier_return('%s')$q$, pg_temp.id('RT2')), '%هو 17 فقط%');
select public.cancel_supplier_return(pg_temp.id('RT2'), 'كمية خاطئة');
reset role;
update public.store_settings set inventory_segregation = false where id = 1;
set constraints all immediate;
do $$ declare c record; begin
  assert pg_temp.stock('00000000-0000-0000-0000-00000000f102') = 17
     and (select qty from public.location_stock where variant_id = '00000000-0000-0000-0000-00000000f102') = 17, 'shipped once: 20 → 17';
  assert (select qty_returned from public.goods_receipt_items where id = pg_temp.gri('00000000-0000-0000-0000-00000000f102')) = 3, 'receipt line returned 3';
  -- الأساس سعر الفاتورة 50، والمتوسط 60 ← 3 × 10 = 30 فرق تكلفة (خسارة)؛ المتوسط لا يتغير
  select * into c from public.cost_adjustments where source_type = 'supplier_return' and source_id = pg_temp.id('RT');
  assert c.variance_delta = 30 and c.stock_delta = 0 and pg_temp.cost('00000000-0000-0000-0000-00000000f102') = 60, format('return variance %s', row_to_json(c));
  assert exists (select 1 from public.location_movements where type = 'supplier_return' and qty_change = -3), 'location movement typed supplier_return';
end $$;
set constraints all deferred;

-- ============ 4) إشعار المرتجع: 3 × 50 = 150 + 22.50 = 172.50، الأقدم أولاً ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
insert into t select 'CNR', public.post_credit_note('00000000-0000-0000-0000-0000000009a1', 'return', pg_temp.id('RT'), null, 'CR-2', current_date);
select pg_temp.expect_error(format($q$select public.post_credit_note('00000000-0000-0000-0000-0000000009a1', 'return', '%s', null, 'CR-3', current_date)$q$, pg_temp.id('RT')), '%مرتجع مشحون%');
reset role;
set constraints all immediate;
do $$ begin
  assert (select total from public.supplier_credit_notes where id = pg_temp.id('CNR')) = 172.50, 'return credit 172.50';
  assert (select status from public.supplier_returns where id = pg_temp.id('RT')) = 'credited', 'return credited';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000009a1') = 2012.50, 'balance 2012.50';
end $$;
set constraints all deferred;

-- ============ 5) سداد الباقي، ثم خصم تجاري 200 (+30) بلا فواتير مفتوحة ← رصيد دائن 230، ثم استرداده ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select public.post_supplier_payment('00000000-0000-0000-0000-0000000009a1', 2012.50, 'bank_transfer', 'TRX-1');
insert into t select 'CNB', public.post_credit_note('00000000-0000-0000-0000-0000000009a1', 'rebate', null, null, 'CR-4', current_date,
  '[{"description":"خصم كمية الربع الثالث","amount":200}]');
do $$ declare r record; begin
  assert (select status from public.supplier_invoices where id = pg_temp.id('INV')) = 'paid', 'invoice paid';
  select * into r from public.supplier_aging() where supplier_id = '00000000-0000-0000-0000-0000000009a1';
  assert r.total_open = 0 and r.unapplied = 230 and r.net_balance = -230 and r.ledger_balance = -230, format('aging with unapplied credit %s', row_to_json(r));
end $$;
select pg_temp.expect_error($q$select public.record_supplier_refund('00000000-0000-0000-0000-0000000009a1', 300, 'bank_transfer', 'IN-1')$q$, '%أكبر من الرصيد الدائن%');
select public.record_supplier_refund('00000000-0000-0000-0000-0000000009a1', 230, 'bank_transfer', 'IN-1', null, null, 'ab000000-0000-0000-0000-000000000003');
select public.record_supplier_refund('00000000-0000-0000-0000-0000000009a1', 230, 'bank_transfer', 'IN-1', null, null, 'ab000000-0000-0000-0000-000000000003');
select pg_temp.expect_error(format($q$select public.void_credit_note('%s', 'x')$q$, pg_temp.id('CNB')), '%استُرد%');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.bal('00000000-0000-0000-0000-0000000009a1') = 0, 'refund closes the credit';
  assert (select count(*) from public.supplier_refunds) = 1, 'refund idempotent';
end $$;
set constraints all deferred;

-- ============ 6) إلغاء إشعار السعر: تحرير التطبيق وعكس التكلفة؛ إلغاء تكاليف الوصول ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select public.void_credit_note(pg_temp.id('CNP'), 'المورد سحب التخفيض');
select pg_temp.expect_error(format($q$select public.void_credit_note('%s', 'مرة ثانية')$q$, pg_temp.id('CNP')), '%ملغى مسبقاً%');
select public.void_landed_cost(pg_temp.id('LCV'), 'فاتورة شحن خاطئة');
reset role;
set constraints all immediate;
do $$ begin
  -- الفاتورة كانت مدفوعة: 115 + 172.50 + 2012.50 = 2300 ← بعد تحرير 115 تصبح مدفوعة جزئياً والرصيد 115
  assert (select status from public.supplier_invoices where id = pg_temp.id('INV')) = 'partially_paid'
     and pg_temp.bal('00000000-0000-0000-0000-0000000009a1') = 115, 'credit void reopens invoice';
  assert exists (select 1 from public.cost_adjustments where source_type = 'credit_note_void' and source_id = pg_temp.id('CNP') and total_delta = 100), 'price credit reversed';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000009b1') = 0 and pg_temp.bal('00000000-0000-0000-0000-0000000009c1') = 0, 'landed cost payables voided';
  assert (select count(*) from public.cost_adjustments where source_type = 'landed_cost_void' and source_id = pg_temp.id('LCV')) = 2, 'landed cost reversed per line';
end $$;
set constraints all deferred;

-- ============ 7) الصلاحيات ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d3');
select pg_temp.expect_error($q$select public.create_supplier_return('00000000-0000-0000-0000-0000000009a1', (select id from public.locations where code = 'MAIN'), '[{"variant_id":"00000000-0000-0000-0000-00000000f102","qty":1}]', 'x')$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.post_credit_note('00000000-0000-0000-0000-0000000009a1', 'rebate', null, null, 'x', current_date, '[{"description":"x","amount":1}]')$q$, 'غير مصرح');
select pg_temp.expect_error($q$select * from public.landed_cost_preview(array[gen_random_uuid()], 1, 'qty')$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.record_supplier_refund('00000000-0000-0000-0000-0000000009a1', 1, 'cash')$q$, 'غير مصرح');
do $$ begin
  assert (select count(*) from public.supplier_credit_notes) = 0 and (select count(*) from public.landed_cost_vouchers) = 0, 'cashier sees no credits';
end $$;
reset role;

set constraints all immediate;
do $$ begin
  assert not exists (select 1 from public.product_variants v
                      where v.stock_qty <> coalesce((select sum(qty) from public.location_stock s where s.variant_id = v.id), 0)), 'location invariant (#8)';
end $$;
rollback;
