-- اختبار 0017 حسابات الموردين (على قاعدة اختبار فقط): الرصيد الافتتاحي، الدفعات وتوزيعها (الأقدم أولاً وصريح)،
-- الدفعة المقدمة وتطبيقها، الدفع من درج الوردية وإلغاؤه، منع التكرار، الكشف، الأعمار، القيد، والصلاحيات
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
create function pg_temp.bal(p uuid) returns numeric language sql as $$ select coalesce((select balance from public.supplier_balances where supplier_id = p), 0) $$;
create function pg_temp.inv(p_k text) returns public.supplier_invoices language sql as $$ select * from public.supplier_invoices where id = pg_temp.id(p_k) $$;
-- فاتورة مرحّلة (تجهيز للاختبار؛ ترحيل فواتير الشراء الفعلي في 0018)
create function pg_temp.posted_invoice(p_k text, p_supplier uuid, p_total numeric, p_due date) returns void language plpgsql as $$
declare v uuid;
begin
  insert into public.supplier_invoices (supplier_id, kind, status, supplier_invoice_no, invoice_date, due_date, subtotal, vat_amount, total, posted_at)
  values (p_supplier, 'purchase', 'posted', p_k, p_due - 30, p_due, round(p_total / 1.15, 2), p_total - round(p_total / 1.15, 2), p_total, now())
  returning id into v;
  perform public._ap_post(p_supplier, 'invoice', v, p_k, 0, p_total);
  insert into t values (p_k, v);
end $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'owner@ap.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000a2', 'manager@ap.test', '{"role":"manager"}'),
  ('00000000-0000-0000-0000-0000000000a3', 'cashier@ap.test', '{"role":"cashier"}');
insert into public.suppliers (id, name, payment_terms_days) values
  ('00000000-0000-0000-0000-0000000005a1', 'مصنع الثياب', 30),
  ('00000000-0000-0000-0000-0000000005b1', 'مورد الأحذية', 0);

-- ============ 1) الرصيد الافتتاحي ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_error($q$select public.set_supplier_opening_balance('00000000-0000-0000-0000-0000000005a1', 1000, current_date - 100, 'قبل النظام')$q$, 'غير مصرح');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_error($q$select public.set_supplier_opening_balance('00000000-0000-0000-0000-0000000005a1', 1000, current_date, ' ')$q$, '%السبب%');
insert into t select 'OPEN', public.set_supplier_opening_balance('00000000-0000-0000-0000-0000000005a1', 1000, current_date - 100, 'رصيد دفتري قبل النظام', 'f0000000-0000-0000-0000-000000000001');
insert into t select 'OPEN2', public.set_supplier_opening_balance('00000000-0000-0000-0000-0000000005a1', 1000, current_date - 100, 'رصيد دفتري قبل النظام', 'f0000000-0000-0000-0000-000000000001');
select pg_temp.expect_error($q$select public.set_supplier_opening_balance('00000000-0000-0000-0000-0000000005a1', 50, current_date, 'مرة ثانية')$q$, '%مسجّل مسبقاً%');
-- سالب = دفعة مقدمة لدى المورد
select public.set_supplier_opening_balance('00000000-0000-0000-0000-0000000005b1', -200, current_date - 10, 'عربون قديم');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.id('OPEN') = pg_temp.id('OPEN2'), 'opening idempotent';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000005a1') = 1000 and pg_temp.bal('00000000-0000-0000-0000-0000000005b1') = -200, 'opening balances';
end $$;
set constraints all deferred;

-- فاتورتان: INV-1 = 575 مستحقة قبل 40 يوماً، INV-2 = 1150 مستحقة بعد 10 أيام
select pg_temp.posted_invoice('INV-1', '00000000-0000-0000-0000-0000000005a1', 575, current_date - 40);
select pg_temp.posted_invoice('INV-2', '00000000-0000-0000-0000-0000000005a1', 1150, current_date + 10);

-- ============ 2) دفعة 1200 نقداً ← الأقدم أولاً: الافتتاحي 1000 كاملاً + 200 من INV-1 ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_error($q$select public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 10, 'cash')$q$, 'غير مصرح');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
insert into t select 'P1', public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 1200, 'cash', null, null, null, 'دفعة', 'f0000000-0000-0000-0000-0000000000c1');
insert into t select 'P1b', public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 1200, 'cash', null, null, null, 'دفعة', 'f0000000-0000-0000-0000-0000000000c1');
select pg_temp.expect_error($q$select public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 100, 'bank_transfer')$q$, '%رقم الحوالة%');
reset role;
set constraints all immediate;
do $$ begin
  assert pg_temp.id('P1') = pg_temp.id('P1b'), 'payment idempotent';
  assert (select status from public.supplier_invoices where id = pg_temp.id('OPEN')) = 'paid', 'opening paid first (oldest)';
  assert (pg_temp.inv('INV-1')).settled_amount = 200 and (pg_temp.inv('INV-1')).status = 'partially_paid', 'INV-1 partially paid 200';
  assert (pg_temp.inv('INV-2')).status = 'posted', 'INV-2 untouched';
  -- 1000 + 575 + 1150 − 1200 = 1525
  assert pg_temp.bal('00000000-0000-0000-0000-0000000005a1') = 1525, 'balance 1525';
  assert (select allocated_amount from public.supplier_payments where id = pg_temp.id('P1')) = 1200, 'fully allocated';
end $$;
set constraints all deferred;

-- ============ 3) توزيع صريح: أخطاء ثم دفع من الدرج وإلغاؤه ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_error(format($q$select public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 500, 'cash', null, null, '[{"invoice_id":"%s","amount":400}]')$q$, pg_temp.id('INV-1')),
  '%أكبر من المتبقي%');
select pg_temp.expect_error(format($q$select public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 100, 'cash', null, null, '[{"invoice_id":"%s","amount":300}]')$q$, pg_temp.id('INV-2')),
  '%أكبر من المبلغ المتاح%');
select pg_temp.expect_error($q$select public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 100, 'cash_drawer')$q$, '%وردية مفتوحة%');
select public.open_shift(500);
insert into t select 'P2', public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 100, 'cash_drawer', null, null,
  jsonb_build_array(jsonb_build_object('invoice_id', pg_temp.id('INV-2'), 'amount', 100)));
reset role;
set constraints all immediate;
do $$ declare v_shift uuid; begin
  select shift_id into v_shift from public.supplier_payments where id = pg_temp.id('P2');
  assert (select count(*) from public.shift_cash_movements where shift_id = v_shift and type = 'out' and amount = 100) = 1, 'drawer out 100';
  -- النقد المتوقع: 500 افتتاحي − 100
  assert (public._shift_numbers(v_shift) ->> 'expected_cash')::numeric = 400, 'expected cash 400';
  assert (pg_temp.inv('INV-2')).settled_amount = 100, 'explicit allocation to INV-2';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000005a1') = 1425, 'balance 1425';
end $$;
set constraints all deferred;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_error(format($q$select public.void_supplier_payment('%s', '')$q$, pg_temp.id('P2')), '%السبب%');
select public.void_supplier_payment(pg_temp.id('P2'), 'أُدخلت بالخطأ');
select pg_temp.expect_error(format($q$select public.void_supplier_payment('%s', 'مرة ثانية')$q$, pg_temp.id('P2')), '%ملغاة مسبقاً%');
reset role;
set constraints all immediate;
do $$ declare v_shift uuid; begin
  select shift_id into v_shift from public.supplier_payments where id = pg_temp.id('P2');
  assert (public._shift_numbers(v_shift) ->> 'expected_cash')::numeric = 500, 'drawer restored on void';
  assert (pg_temp.inv('INV-2')).settled_amount = 0 and (pg_temp.inv('INV-2')).status = 'posted', 'allocation released';
  assert pg_temp.bal('00000000-0000-0000-0000-0000000005a1') = 1525, 'balance back to 1525';
  assert exists (select 1 from public.supplier_ledger where entry_type = 'void_payment' and source_id = pg_temp.id('P2') and credit = 100), 'reversal entry';
end $$;
set constraints all deferred;

-- دفعة درج من وردية أُغلقت لا تُلغى
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
insert into t select 'P3', public.post_supplier_payment('00000000-0000-0000-0000-0000000005a1', 50, 'cash_drawer');
select public.close_shift((select id from public.shifts where cashier_id = '00000000-0000-0000-0000-0000000000a2' and status = 'open'), 450);
select pg_temp.expect_error(format($q$select public.void_supplier_payment('%s', 'تأخرنا')$q$, pg_temp.id('P3')), '%وردية الدفع مغلقة%');

-- ============ 4) الدفعة المقدمة: مورد الأحذية (مقدّم 200) + دفعة 500 بلا فواتير ← مقدّم 700 ============
insert into t select 'PB', public.post_supplier_payment('00000000-0000-0000-0000-0000000005b1', 500, 'bank_transfer', 'TRX-778');
reset role;
select pg_temp.posted_invoice('INV-B1', '00000000-0000-0000-0000-0000000005b1', 300, current_date + 5);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
do $$ begin
  assert public.allocate_supplier_credit('payment', pg_temp.id('PB')) = 300, 'advance applied 300 to new invoice';
end $$;
select pg_temp.expect_error(format($q$select public.allocate_supplier_credit('payment', '%s')$q$, pg_temp.id('PB')), '%لا توجد فواتير مفتوحة%');
reset role;
set constraints all immediate;
do $$ begin
  assert (pg_temp.inv('INV-B1')).status = 'paid', 'INV-B1 paid from advance';
  -- −200 − 500 + 300 = −400 (مقدّم 400 لدى المورد)
  assert pg_temp.bal('00000000-0000-0000-0000-0000000005b1') = -400, 'supplier B advance 400';
end $$;
set constraints all deferred;

-- ============ 5) الكشف والأعمار ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
do $$ declare r record; v_last numeric; begin
  select balance into v_last from public.supplier_statement('00000000-0000-0000-0000-0000000005a1') order by entry_date desc, entry_id desc nulls last limit 1;
  -- 1525 − 50 (دفعة الدرج P3 إلى INV-1 الأقدم)
  assert v_last = 1475, format('statement closing %s', v_last);
  select * into r from public.supplier_statement('00000000-0000-0000-0000-0000000005a1', current_date - 50) where entry_id is null;
  assert r.balance = 1000, format('balance brought forward %s', r.balance);

  select * into r from public.supplier_aging() where supplier_id = '00000000-0000-0000-0000-0000000005a1';
  -- INV-1: 575 − 200 − 50 = 325 متأخرة 40 يوماً ← 31–60. INV-2: 1150 غير مستحقة
  assert r.d31_60 = 325 and r.not_due = 1150 and r.total_open = 1475 and r.net_balance = 1475 and r.ledger_balance = 1475,
    format('aging A: %s', row_to_json(r));
  select * into r from public.supplier_aging() where supplier_id = '00000000-0000-0000-0000-0000000005b1';
  assert r.total_open = 0 and r.unapplied = 400 and r.net_balance = -400, format('aging B: %s', row_to_json(r));
  -- بعد 25 يوماً: INV-2 متأخرة 15 يوماً ← 1–30، وINV-1 متأخرة 65 ← 61–90
  select * into r from public.supplier_aging(current_date + 25) where supplier_id = '00000000-0000-0000-0000-0000000005a1';
  assert r.d1_30 = 1150 and r.d61_90 = 325, 'aging moves with the date';
  assert (public.supplier_profile('00000000-0000-0000-0000-0000000005a1') ->> 'overdue_total')::numeric = 325, 'profile overdue';
  assert (select count(*) from public.supplier_open_documents('00000000-0000-0000-0000-0000000005a1')) = 2, 'two open documents';
end $$;

-- ============ 6) الصلاحيات ============
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_error($q$select * from public.supplier_statement('00000000-0000-0000-0000-0000000005a1')$q$, 'غير مصرح');
select pg_temp.expect_error($q$select * from public.supplier_aging()$q$, 'غير مصرح');
select pg_temp.expect_error($q$insert into public.supplier_payments (supplier_id, amount, method) values ('00000000-0000-0000-0000-0000000005a1', 1, 'cash')$q$, '%permission denied%');
select pg_temp.expect_error($q$update public.supplier_balances set balance = 0$q$, '%permission denied%');
select pg_temp.expect_error($q$select public._ap_post('00000000-0000-0000-0000-0000000005a1', 'payment', gen_random_uuid(), 'x', 1, 0)$q$, '%permission denied%');
do $$ begin
  assert (select count(*) from public.supplier_ledger) = 0 and (select count(*) from public.supplier_invoices) = 0, 'cashier sees nothing';
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_error($q$insert into public.supplier_ledger (supplier_id, entry_type, source_id, credit, balance_after) values ('00000000-0000-0000-0000-0000000005a1', 'invoice', gen_random_uuid(), 1, 1)$q$, '%permission denied%');
reset role;

-- ============ 7) القيد: أي عبث بالرصيد أو المسدَّد يُرفض عند نهاية المعاملة ============
set constraints all immediate;
select pg_temp.expect_error($q$update public.supplier_balances set balance = balance + 1 where supplier_id = '00000000-0000-0000-0000-0000000005a1'$q$, '%تعارض حساب المورد%');
select pg_temp.expect_error(format($q$update public.supplier_invoices set settled_amount = 0 where id = '%s'$q$, pg_temp.id('INV-1')), '%تعارض المسدَّد%');
-- لا قيد مكرر لنفس المستند
select pg_temp.expect_error(format($q$select public._ap_post('00000000-0000-0000-0000-0000000005a1', 'payment', '%s', 'x', 1, 0)$q$, pg_temp.id('P1')), '%supplier_ledger_unique_source%');

rollback;
