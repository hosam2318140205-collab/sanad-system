-- اختبار Sales & Customers 2.0 (على قاعدة اختبار فقط)
-- البيع النقدي/الشبكة/الآجل/الجزئي، منع الترحيل المزدوج، العروض والكوبونات والصلاحية، الولاء،
-- التحصيل وكشف الحساب والإلغاء، المرتجع والاستبدال مع الذمم والنقاط، الحجز والعربون، رابط/QR الفاتورة،
-- الصلاحيات، والضريبة 15% (شامل/غير شامل). الأرقام المتوقعة محسوبة يدوياً في التعليقات.
\set ON_ERROR_STOP 1
begin;

-- مساعد: يتوقع فشل الأمر برسالة تطابق النمط
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
grant all on t to authenticated, anon;
create function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'owner@sc.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000a2', 'cashier@sc.test', '{"role":"cashier"}'),
  ('00000000-0000-0000-0000-0000000000a3', 'manager@sc.test', '{"role":"manager"}');

insert into public.categories (id, name) values
  ('00000000-0000-0000-0000-0000000000d1', 'قمصان'), ('00000000-0000-0000-0000-0000000000d2', 'بناطيل');
insert into public.products (id, name, base_price, category_id) values
  ('00000000-0000-0000-0000-0000000000b1', 'قميص', 100, '00000000-0000-0000-0000-0000000000d1'),
  ('00000000-0000-0000-0000-0000000000b2', 'بنطلون', 200, '00000000-0000-0000-0000-0000000000d2'),
  ('00000000-0000-0000-0000-0000000000b3', 'جوارب', 20, '00000000-0000-0000-0000-0000000000d2');
insert into public.product_variants (id, product_id, sku, size, color, stock_qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 'SH-M-BLK', 'M', 'أسود', 50),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b1', 'SH-L-BLK', 'L', 'أسود', 50),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b2', 'PN-32-NVY', '32', 'كحلي', 10),
  ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000b3', 'SK-WHT', null, 'أبيض', 100);
insert into public.customers (id, name, phone) values
  ('00000000-0000-0000-0000-0000000000e1', 'عميل آجل', '0501234567'),
  ('00000000-0000-0000-0000-0000000000e2', 'عميل ولاء', '0559876543');
update public.store_settings set loyalty_enabled = true, loyalty_points_per_sar = 0.1, loyalty_point_value = 0.1,
  loyalty_min_redeem = 50, loyalty_max_redeem_pct = 50 where id = 1;

set local role authenticated;
-- ورديات مفتوحة للمالك والكاشير
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select public.open_shift(0);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select public.open_shift(0);

-- ============ 1) بيع نقدي: 100 شامل الضريبة ← الضريبة 100×15/115 = 13.04 ============
insert into t select 's1', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]', '[{"method":"cash","amount":100}]');
do $$ declare v public.sales; begin
  select * into v from public.sales where id = pg_temp.id('s1');
  assert v.total = 100 and v.vat_amount = 13.04 and v.subtotal = 86.96, format('cash sale %s/%s', v.total, v.vat_amount);
  assert v.public_token ~ '^[0-9a-f]{32}$', 'public token';
end $$;

-- ============ 2) منع الترحيل المزدوج: نفس client_ref مرتين = فاتورة واحدة وحركة مخزون واحدة ============
insert into t select 'idem1', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]',
  '[{"method":"card","amount":100}]', null, 0, null, 'f0000000-0000-0000-0000-000000000001');
insert into t select 'idem2', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]',
  '[{"method":"card","amount":100}]', null, 0, null, 'f0000000-0000-0000-0000-000000000001');
do $$ begin
  assert pg_temp.id('idem1') = pg_temp.id('idem2'), 'same client_ref returns same sale';
  assert (select count(*) from public.sales where client_ref = 'f0000000-0000-0000-0000-000000000001') = 1, 'one sale';
  assert (select stock_qty from public.product_variants where id = '00000000-0000-0000-0000-0000000000c1') = 48, 'stock moved once';
end $$;

-- ============ 3) شبكة لعميل: 200 ← يكسب ⌊200×0.1⌋ = 20 نقطة ============
insert into t select 's3', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]',
  '[{"method":"card","amount":200}]', '00000000-0000-0000-0000-0000000000e2');
do $$ begin
  assert (select loyalty_points from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e2') = 20, 'earned 20';
  assert (select loyalty_points_earned from public.sales where id = pg_temp.id('s3')) = 20, 'sale records earned';
end $$;

-- ============ 4) العروض ============
-- أ) 20% على القمصان: قميصان 200 ← خصم 40 ← 160، الضريبة 160×15/115 = 20.87
insert into public.promotions (id, name, kind, value, scope, category_id)
values ('00000000-0000-0000-0000-0000000000f1', 'خصم القمصان', 'percent', 20, 'category', '00000000-0000-0000-0000-0000000000d1');
do $$ declare p jsonb; begin
  p := public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":2}]');
  assert (p ->> 'total')::numeric = 160 and (p ->> 'promo_discount')::numeric = 40, 'preview promo ' || (p ->> 'total');
end $$;
insert into t select 's4a', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":2}]', '[{"method":"cash","amount":160}]');
do $$ declare v public.sales; begin
  select * into v from public.sales where id = pg_temp.id('s4a');
  assert v.total = 160 and v.vat_amount = 20.87 and v.promo_discount = 40, format('promo sale %s/%s', v.total, v.vat_amount);
  assert (select promotion_id from public.sale_items where sale_id = v.id) = '00000000-0000-0000-0000-0000000000f1', 'promotion linked';
end $$;

-- الكاشير: خصم يدوي 10% فوق عرض 20% مسموح (حد الكاشير يحسب خصومه اليدوية فقط): 100 − 20 − 10 = 70
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
do $$ declare v_id uuid; begin
  v_id := public.complete_sale(
    '[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1,"discount":10}]', '[{"method":"cash","amount":70}]');
  assert (select total from public.sales where id = v_id) = 70, 'cashier manual discount on top of promo';
end $$;
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1,"discount":11}]', '[{"method":"cash","amount":69}]')$q$,
  '%الحد المسموح للكاشير%');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);

-- ب) اشترِ 2 واحصل على 1 مجاناً على القميص: 3 قطع × 100 ← خصم 100 (أفضل من 20% = 60، ولا تراكب)
insert into public.promotions (id, name, kind, buy_qty, get_qty, scope, product_id)
values ('00000000-0000-0000-0000-0000000000f2', '2+1 قمصان', 'bxgy', 2, 1, 'product', '00000000-0000-0000-0000-0000000000b1');
do $$ declare p jsonb; begin
  p := public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":2},{"variant_id":"00000000-0000-0000-0000-0000000000c2","qty":1}]');
  assert (p ->> 'total')::numeric = 200 and (p ->> 'promo_discount')::numeric = 100, 'bxgy best wins ' || (p ->> 'total');
  assert jsonb_array_length(p -> 'promotions') = 1 and p -> 'promotions' -> 0 ->> 'name' = '2+1 قمصان', 'single promo applied';
end $$;
update public.promotions set is_active = false where id in ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2');

-- ج) كوبون 10 ر.س لكل قطعة جوارب: بدون الرمز لا خصم، مع الرمز (بحروف صغيرة) 3×20 − 30 = 30
insert into public.promotions (id, name, kind, value, scope, product_id, code)
values ('00000000-0000-0000-0000-0000000000f3', 'كوبون الجوارب', 'amount', 10, 'product', '00000000-0000-0000-0000-0000000000b3', 'socks10');
do $$ begin
  assert (select code from public.promotions where id = '00000000-0000-0000-0000-0000000000f3') = 'SOCKS10', 'code normalized';
  assert (public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":3}]') ->> 'total')::numeric = 60, 'no code no discount';
end $$;
insert into t select 's4c', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":3}]',
  '[{"method":"cash","amount":30}]', null, 0, null, null, 'socks10');
do $$ begin
  assert (select total = 30 and promo_code = 'SOCKS10' from public.sales where id = pg_temp.id('s4c')), 'coupon applied';
end $$;
select pg_temp.expect_error($q$select public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":1}]', 0, 'NOPE')$q$, '%غير صالح%');
-- كوبون منتهي
update public.promotions set starts_at = now() - interval '10 days', ends_at = now() - interval '1 day'
 where id = '00000000-0000-0000-0000-0000000000f3';
select pg_temp.expect_error($q$select public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":1}]', 0, 'SOCKS10')$q$, '%منتهي%');
-- د) عرض تلقائي منتهي الصلاحية لا يُطبق، وعرض لم يبدأ بعد لا يُطبق
insert into public.promotions (name, kind, value, starts_at, ends_at) values
  ('منتهي', 'percent', 50, now() - interval '5 days', now() - interval '1 day'),
  ('قادم', 'percent', 50, now() + interval '1 day', null);
do $$ begin
  assert (public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":1}]') ->> 'total')::numeric = 20, 'out-of-date promos ignored';
end $$;
update public.promotions set is_active = false;

-- ============ 5) الولاء ============
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]', '[{"method":"card","amount":198}]', '00000000-0000-0000-0000-0000000000e2', 0, null, null, null, 20)$q$,
  '%الحد الأدنى%');
select public.adjust_loyalty('00000000-0000-0000-0000-0000000000e2', 100, 'تعويض عميل');          -- 120
-- 100 نقطة = 10 ر.س خصم ← 190، الضريبة 190×15/115 = 24.78، ويكسب ⌊190×0.1⌋ = 19 ← 120 − 100 + 19 = 39
insert into t select 's5', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]',
  '[{"method":"card","amount":190}]', '00000000-0000-0000-0000-0000000000e2', 0, null, null, null, 100);
do $$ declare v public.sales; begin
  select * into v from public.sales where id = pg_temp.id('s5');
  assert v.total = 190 and v.vat_amount = 24.78 and v.loyalty_discount = 10 and v.loyalty_points_redeemed = 100,
    format('loyalty sale %s/%s/%s', v.total, v.vat_amount, v.loyalty_discount);
  assert (select loyalty_points from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e2') = 39, 'points 39';
end $$;
select public.adjust_loyalty('00000000-0000-0000-0000-0000000000e2', 1000, 'حملة');                -- 1039
-- 200 نقطة = 20 ر.س على فاتورة 20 ر.س > 50%
select pg_temp.expect_error($q$select public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":1}]', 0, null, 200, '00000000-0000-0000-0000-0000000000e2')$q$, '%تتجاوز الحد%');
select pg_temp.expect_error($q$select public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]', 0, null, 5000, '00000000-0000-0000-0000-0000000000e2')$q$, '%غير كافٍ%');
select pg_temp.expect_error($q$select public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]', 0, null, 100, null)$q$, '%اختر العميل%');

-- ============ 6) البيع الآجل والجزئي ============
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a3', true);
select public.set_credit_limit('00000000-0000-0000-0000-0000000000e1', 500);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]', '[{"method":"cash","amount":50},{"method":"on_account","amount":150}]', '00000000-0000-0000-0000-0000000000e1')$q$,
  '%غير مسموح للكاشير%');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
update public.store_settings set allow_cashier_credit = true where id = 1;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
-- 50 نقداً + 150 آجل ← ذمة 150، ونقاط على المدفوع فقط ⌊50×0.1⌋ = 5
insert into t select 's6', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]',
  '[{"method":"cash","amount":50},{"method":"on_account","amount":150}]', '00000000-0000-0000-0000-0000000000e1');
do $$ begin
  assert (select account_balance = 150 and loyalty_points = 5 from public.customer_accounts
           where customer_id = '00000000-0000-0000-0000-0000000000e1'), 'credit balance 150, points 5';
  assert (select count(*) from public.customer_ledger where customer_id = '00000000-0000-0000-0000-0000000000e1') = 1, 'one AR entry';
end $$;
-- 150 + 400 = 550 > 500
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":2}]', '[{"method":"on_account","amount":400}]', '00000000-0000-0000-0000-0000000000e1')$q$, '%حد الائتمان%');
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":1}]', '[{"method":"on_account","amount":20}]')$q$, '%يتطلب اختيار العميل%');
-- عميل بلا حد ائتمان
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c4","qty":1}]', '[{"method":"on_account","amount":20}]', '00000000-0000-0000-0000-0000000000e2')$q$, '%حد الائتمان%');

-- ============ 7) التحصيل ============
insert into t select 'r1', public.record_customer_payment('00000000-0000-0000-0000-0000000000e1', 100, 'cash_drawer', 'receipt',
  null, 'دفعة', 'f0000000-0000-0000-0000-0000000000a1');
insert into t select 'r1b', public.record_customer_payment('00000000-0000-0000-0000-0000000000e1', 100, 'cash_drawer', 'receipt',
  null, 'دفعة', 'f0000000-0000-0000-0000-0000000000a1');
do $$ begin
  assert pg_temp.id('r1') = pg_temp.id('r1b'), 'same client_ref, same receipt';
  assert (select account_balance from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e1') = 50, 'balance 50 after one receipt';
  assert (select count(*) from public.shift_cash_movements m join public.customer_payments p on p.shift_movement_id = m.id
           where p.id = pg_temp.id('r1') and m.type = 'in' and m.amount = 100), 'drawer cash-in recorded';
end $$;
select pg_temp.expect_error($q$select public.record_customer_payment('00000000-0000-0000-0000-0000000000e1', 10, 'cash')$q$, '%عبر الدرج%');
select pg_temp.expect_error($q$select public.record_customer_payment('00000000-0000-0000-0000-0000000000e1', 10, 'card', 'refund')$q$, '%للمدير فقط%');

-- ============ 8) كشف الحساب ============
do $$ declare st jsonb; begin
  st := public.customer_statement('00000000-0000-0000-0000-0000000000e1');
  assert (st ->> 'opening_balance')::numeric = 0 and (st ->> 'closing_balance')::numeric = 50, 'statement balances';
  assert jsonb_array_length(st -> 'entries') = 2 and (st -> 'entries' -> 1 ->> 'balance')::numeric = 50, 'running balance';
  assert (st ->> 'total_debit')::numeric = 150 and (st ->> 'total_credit')::numeric = 100, 'statement totals';
  -- فترة لاحقة: الرصيد الافتتاحي = 50 ولا حركات
  st := public.customer_statement('00000000-0000-0000-0000-0000000000e1', current_date + 1, current_date + 2);
  assert (st ->> 'opening_balance')::numeric = 50 and jsonb_array_length(st -> 'entries') = 0, 'opening carried';
end $$;

-- ============ 9) مرتجع فاتورة آجلة ============
-- المدفوع فعلاً 50 فقط: الرد النقدي لـ 200 مرفوض
select pg_temp.expect_error($q$select public.process_return((select id from t where k = 's6'), jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = (select id from t where k = 's6')), 'qty', 1)), 'cash')$q$,
  '%جزء من هذه الفاتورة آجل%');
-- إلى حساب العميل: 50 − 200 = −150 (رصيد دائن)، وتُعكس النقاط الخمس
insert into t select 'ret6', public.process_return(pg_temp.id('s6'),
  jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = pg_temp.id('s6')), 'qty', 1)), 'account', 'مقاس');
do $$ begin
  assert (select account_balance = -150 and loyalty_points = 0 from public.customer_accounts
           where customer_id = '00000000-0000-0000-0000-0000000000e1'), 'account refund + points reversed';
  assert (select credit from public.customer_ledger where entry_type = 'return' and source_id = pg_temp.id('ret6')) = 200, 'AR credit';
end $$;
-- رد الرصيد الدائن نقداً (المدير فقط، ولا يتجاوز الرصيد)
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select pg_temp.expect_error($q$select public.record_customer_payment('00000000-0000-0000-0000-0000000000e1', 151, 'cash_drawer', 'refund')$q$, '%رصيد دائن%');
insert into t select 'payout', public.record_customer_payment('00000000-0000-0000-0000-0000000000e1', 150, 'cash_drawer', 'refund');
do $$ begin
  assert (select account_balance from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e1') = 0, 'paid out';
  assert (select m.type = 'out' from public.shift_cash_movements m join public.customer_payments p on p.shift_movement_id = m.id
           where p.id = pg_temp.id('payout')), 'drawer cash-out';
end $$;

-- ============ 10) إلغاء سند التحصيل ============
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select pg_temp.expect_error($q$select public.void_customer_payment((select id from t where k = 'r1'), 'خطأ')$q$, 'غير مصرح');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select public.void_customer_payment(pg_temp.id('r1'), 'مبلغ مسجل بالخطأ');
do $$ begin
  assert (select account_balance from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e1') = 100, 'void restores balance';
  assert (select count(*) from public.shift_cash_movements where reason like 'إلغاء RCP-%' and type = 'out' and amount = 100) = 1, 'drawer reversal';
  assert (select voided_at is not null from public.customer_payments where id = pg_temp.id('r1')), 'marked void';
end $$;
select pg_temp.expect_error($q$select public.void_customer_payment((select id from t where k = 'r1'), 'مرة ثانية')$q$, '%ملغي مسبقاً%');

-- ============ 11) الاستبدال والنقاط ============
-- إرجاع فاتورة 3 (كسبت 20) كرصيد استبدال ← تُعكس 20: 1039 − 20 = 1019
insert into t select 'ret3', public.process_return(pg_temp.id('s3'),
  jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = pg_temp.id('s3')), 'qty', 1)), 'exchange');
-- فاتورة جديدة مدفوعة برصيد الاستبدال بالكامل: لا نقاط جديدة (⌊(200 − 200)×0.1⌋ = 0)
insert into t select 's11', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":2}]',
  jsonb_build_array(jsonb_build_object('method', 'exchange_credit', 'amount', 200, 'return_id', pg_temp.id('ret3'))),
  '00000000-0000-0000-0000-0000000000e2');
do $$ begin
  assert (select loyalty_points from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e2') = 1019, 'exchange: reverse 20, earn 0';
  assert (select credit_used_by_sale from public.returns where id = pg_temp.id('ret3')) = pg_temp.id('s11'), 'credit consumed';
end $$;
-- إرجاع فاتورة النقاط (استبدلت 100 وكسبت 19): تُعكس 19 وتُسترجع 100 ← 1019 − 19 + 100 = 1100
select public.process_return(pg_temp.id('s5'),
  jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = pg_temp.id('s5')), 'qty', 1)), 'card');
do $$ begin
  assert (select loyalty_points from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e2') = 1100, 'points restored on return';
  -- المرتجع يرد صافي ما دُفع بعد خصم النقاط (190) كما في منطق المرتجعات الحالي
  assert (select total from public.returns where sale_id = (select id from t where k = 's5')) = 190, 'refund = net paid';
end $$;

-- ============ 12) الحجز والعربون ============
-- البنطلون: 10 − 1 (3) − 1 (5) − 1 (6) + 1 (مرتجع 6) + 1 (مرتجع 3) + 1 (مرتجع 5) = 10
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
insert into t select 'res1', public.create_reservation('00000000-0000-0000-0000-0000000000e2',
  '[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":10}]', 3, 'مقاس 32', 'f0000000-0000-0000-0000-0000000000b1');
insert into t select 'res1b', public.create_reservation('00000000-0000-0000-0000-0000000000e2',
  '[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":10}]', 3, 'مقاس 32', 'f0000000-0000-0000-0000-0000000000b1');
do $$ begin
  assert pg_temp.id('res1') = pg_temp.id('res1b'), 'reservation idempotent';
  assert (select stock_qty from public.product_variants where id = '00000000-0000-0000-0000-0000000000c3') = 10, 'stock untouched by reservation';
  assert (select reserved from public.reserved_quantities() where variant_id = '00000000-0000-0000-0000-0000000000c3') = 10, 'reserved 10';
  assert (public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]') -> 'reserved' ->> '00000000-0000-0000-0000-0000000000c3')::integer = 10, 'preview shows reserved';
end $$;
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]', '[{"method":"cash","amount":200}]')$q$, '%محجوز%');
select pg_temp.expect_error($q$select public.create_reservation('00000000-0000-0000-0000-0000000000e1', '[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]')$q$, '%المتاح للحجز%');
-- عربون 50 على الحجز ← رصيد دائن للعميل −50
insert into t select 'dep', public.record_customer_payment('00000000-0000-0000-0000-0000000000e2', 50, 'card', 'receipt',
  'POS-1', 'عربون', null, pg_temp.id('res1'));
select pg_temp.expect_error($q$select public.record_customer_payment('00000000-0000-0000-0000-0000000000e1', 50, 'card', 'receipt', null, null, null, (select id from t where k = 'res1'))$q$, '%لا يخص%');
-- الاستلام: يأخذ قطعتين 400 = 50 من العربون (آجل يستهلك الرصيد الدائن) + 350 شبكة، والعميل يُحدد من الحجز
insert into t select 's12', public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":2}]',
  '[{"method":"on_account","amount":50},{"method":"card","amount":350}]', null, 0, null, null, null, 0, pg_temp.id('res1'));
do $$ begin
  assert (select customer_id from public.sales where id = pg_temp.id('s12')) = '00000000-0000-0000-0000-0000000000e2', 'customer from reservation';
  assert (select status = 'fulfilled' and sale_id = pg_temp.id('s12') from public.reservations where id = pg_temp.id('res1')), 'fulfilled';
  assert (select account_balance from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e2') = 0, 'deposit consumed';
  assert not exists (select 1 from public.reserved_quantities() where variant_id = '00000000-0000-0000-0000-0000000000c3'), 'rest released';
  -- العربون مدفوع مسبقاً فيُحتسب في النقاط: ⌊400×0.1⌋ = 40 ← 1100 + 40 = 1140
  assert (select loyalty_points from public.customer_accounts where customer_id = '00000000-0000-0000-0000-0000000000e2') = 1140, 'points on deposit-paid sale';
end $$;
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]', '[{"method":"card","amount":200}]', null, 0, null, null, null, 0, (select id from t where k = 'res1'))$q$, '%تم إغلاقه%');
-- القطع المتبقية أصبحت متاحة للبيع
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c3","qty":1}]', '[{"method":"cash","amount":200}]');

-- الإلغاء: الكاشير لا يلغي حجز غيره، والمدير يلغي أي حجز
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
insert into t select 'res3', public.create_reservation('00000000-0000-0000-0000-0000000000e1', '[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]');
select pg_temp.expect_error($q$select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]', '[{"method":"cash","amount":100}]', '00000000-0000-0000-0000-0000000000e2', 0, null, null, null, 0, (select id from t where k = 'res3'))$q$, '%لعميل آخر%');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select pg_temp.expect_error($q$select public.cancel_reservation((select id from t where k = 'res3'), 'لا')$q$, '%حجوزاته فقط%');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a3', true);
select public.cancel_reservation(pg_temp.id('res3'), 'العميل اعتذر');
do $$ begin
  assert (select status from public.reservations where id = pg_temp.id('res3')) = 'cancelled', 'cancelled';
end $$;
-- الانتهاء: حجز منتهٍ لا يحجز شيئاً، والتمديد يعيده
insert into t select 'res4', public.create_reservation('00000000-0000-0000-0000-0000000000e1', '[{"variant_id":"00000000-0000-0000-0000-0000000000c2","qty":2}]', 1);
reset role;
update public.reservations set expires_at = now() - interval '1 hour' where id = (select id from t where k = 'res4');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a3', true);
do $$ begin
  assert not exists (select 1 from public.reserved_quantities() where variant_id = '00000000-0000-0000-0000-0000000000c2'), 'expired frees stock';
  assert public.extend_reservation(pg_temp.id('res4'), 2) > now(), 'extended';
  assert (select reserved from public.reserved_quantities() where variant_id = '00000000-0000-0000-0000-0000000000c2') = 2, 'reserved again';
end $$;

-- ============ 13) رابط الفاتورة والـ QR ============
do $$ declare v_token text; v_no text; begin
  select public_token, invoice_no into v_token, v_no from public.sales where id = pg_temp.id('s1');
  assert public.resolve_invoice_ref('https://shop.example/r/' || v_token) = v_no, 'resolve by QR url';
  assert public.resolve_invoice_ref(lower(v_no)) = v_no, 'resolve by invoice no';
end $$;
select pg_temp.expect_error($q$select public.resolve_invoice_ref('INV-NOPE')$q$, '%غير موجودة%');
reset role;
create temp table t_tok as select public_token from public.sales where id = (select id from t where k = 's1');
grant select on t_tok to anon;
set local role anon;
do $$ declare v_token text; r jsonb; begin
  v_token := (select public_token from t_tok);
  r := public.public_receipt(v_token);
  assert r ->> 'invoice_no' like 'INV-%' and (r ->> 'total')::numeric = 100, 'anon public receipt';
  assert r -> 'items' -> 0 ->> 'product_name' = 'قميص' and not (r ? 'customer') , 'no customer data';
  assert public.public_receipt('0123') is null and public.public_receipt(repeat('a', 32)) is null, 'bad token';
end $$ ;
select pg_temp.expect_error($q$select count(*) from public.sales$q$, '%permission denied%');
select pg_temp.expect_error($q$select public.price_cart('[]')$q$, '%permission denied%');
reset role;

-- ============ 14) الصلاحيات ============
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', true);
select pg_temp.expect_error($q$select public.set_credit_limit('00000000-0000-0000-0000-0000000000e2', 1000)$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.adjust_loyalty('00000000-0000-0000-0000-0000000000e2', 10, 'x')$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.receivables_report()$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.customer_analytics(current_date, current_date)$q$, 'غير مصرح');
select pg_temp.expect_error($q$insert into public.promotions (name, kind, value) values ('x', 'percent', 5)$q$, '%row-level security%');
select pg_temp.expect_error($q$insert into public.customer_ledger (customer_id, entry_type, source_id, debit, balance_after) values ('00000000-0000-0000-0000-0000000000e1', 'adjust', gen_random_uuid(), 1, 1)$q$, '%permission denied%');
select pg_temp.expect_error($q$update public.customer_accounts set account_balance = 0$q$, '%permission denied%');
select pg_temp.expect_error($q$update public.customer_accounts set loyalty_points = 99999$q$, '%permission denied%');
-- سجل واتساب: الكاشير يسجل باسمه فقط
insert into public.message_log (kind, sale_id, customer_id, phone)
values ('receipt', (select id from t where k = 's12'), '00000000-0000-0000-0000-0000000000e2', '966559876543');
select pg_temp.expect_error($q$insert into public.message_log (kind, phone, created_by) values ('receipt', '966500000000', '00000000-0000-0000-0000-0000000000a1')$q$, '%row-level security%');
-- الكاشير يرى ملف العميل ورصيده (بدون تكلفة)
do $$ declare p jsonb; begin
  p := public.customer_profile('00000000-0000-0000-0000-0000000000e2');
  assert (p -> 'account' ->> 'loyalty_points')::integer = 1140, 'profile points';
  assert (p -> 'stats' ->> 'invoices')::integer = 4, 'profile invoices ' || (p -> 'stats' ->> 'invoices');
  assert p -> 'favorite_sizes' -> 0 ->> 'label' in ('32', 'M'), 'favorite size';
  assert p::text not like '%unit_cost%' and p::text not like '%cost_price%', 'no cost in profile';
  assert (p ->> 'messages')::integer = 1, 'message logged';
end $$;

-- ============ 15) التحليلات والذمم (المدير) ============
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a3', true);
do $$ declare a jsonb; r jsonb; begin
  a := public.customer_analytics(current_date - 1, current_date);
  -- المحصّل غير الملغي: عربون 50 فقط (سند 100 أُلغي)، والآجل: 150 + 50
  assert (a -> 'credit' ->> 'collections')::numeric = 50, 'collections ' || (a -> 'credit' ->> 'collections');
  assert (a -> 'credit' ->> 'credit_sales')::numeric = 200, 'credit sales ' || (a -> 'credit' ->> 'credit_sales');
  assert (a -> 'loyalty' ->> 'points_outstanding')::integer = 1140, 'points outstanding';
  assert (a -> 'loyalty' ->> 'liability')::numeric = 114, 'liability 1140 × 0.1';
  assert (a ->> 'customers_active')::integer = 2, 'active customers';
  r := public.receivables_report();
  assert (r ->> 'total_receivable')::numeric = 100 and (r ->> 'd0_30')::numeric = 100, 'receivables + aging';
end $$;

-- ============ 16) أسعار غير شاملة الضريبة: 100 نقطة = 10 ر.س تُخصم من الإجمالي بالضبط ============
-- أساس الخصم = 10×100/115 = 8.70 ← الصافي 91.30، الضريبة 13.70، الإجمالي 105.00 (بدلاً من 115)
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
update public.store_settings set prices_include_vat = false where id = 1;
do $$ declare p jsonb; begin
  p := public.price_cart('[{"variant_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]', 0, null, 100, '00000000-0000-0000-0000-0000000000e2');
  assert (p ->> 'loyalty_discount')::numeric = 8.70 and (p ->> 'vat')::numeric = 13.70 and (p ->> 'total')::numeric = 105.00,
    format('excl vat loyalty %s/%s/%s', p ->> 'loyalty_discount', p ->> 'vat', p ->> 'total');
end $$;
update public.store_settings set prices_include_vat = true where id = 1;

-- ============ 17) الدفتر يرفض ترحيل نفس المستند مرتين ============
reset role;
select pg_temp.expect_error($q$select public._post_ar('00000000-0000-0000-0000-0000000000e1', 'sale', (select id from t where k = 's6'), 'X', 1, 0)$q$, '%ledger_unique_source%');
select pg_temp.expect_error($q$select public._post_loyalty('00000000-0000-0000-0000-0000000000e2', 'earn', (select id from t where k = 's3'), 'X', 5)$q$, '%loyalty_unique_source%');
-- الدوال الداخلية غير متاحة للمستخدمين
set local role authenticated;
select pg_temp.expect_error($q$select public._post_ar('00000000-0000-0000-0000-0000000000e1', 'adjust', gen_random_uuid(), 'X', 1, 0)$q$, '%permission denied%');
reset role;

-- الأرصدة المجمّعة = مجموع الدفاتر
do $$ begin
  assert not exists (
    select 1 from public.customer_accounts a
     where a.account_balance <> coalesce((select sum(debit - credit) from public.customer_ledger l where l.customer_id = a.customer_id), 0)
        or a.loyalty_points <> coalesce((select sum(points) from public.loyalty_ledger l where l.customer_id = a.customer_id), 0)
  ), 'cached balances match ledgers';
end $$;

rollback;
