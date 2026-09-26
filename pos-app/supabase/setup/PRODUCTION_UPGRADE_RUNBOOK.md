# النشر المنظم — المرحلة 1: PR #7 (Sales & Customers 2.0)

> **النطاق:** ترقيات قاعدة البيانات `0009 → 0010 → 0011 → 0012` ثم دمج PR #7 فقط. لا شيء من #8 أو #9.
> **كل الاستعلامات هنا قراءة فقط** ما عدا ملفات الترقية الأربعة. لا حذف، لا إعادة إنشاء، لا بيانات تجريبية.
> التنفيذ من Supabase → **SQL Editor**. **أي خطأ = توقف** وأرسل نص الخطأ كما هو، ولا تنتقل للخطوة التالية.
> جُرّب كل ما في هذا الملف حرفياً على نسخة مطابقة لقاعدة Production (main + بيانات فعلية + ورديات مفتوحة): كل التحققات طابقت المتوقع، ولقطتا «قبل» و«بعد» متطابقتان.

## لماذا الترتيب آمن
- كل ملف معاملة واحدة (`begin … commit`): إما ينجح كله أو لا يتغير شيء. إن نُفّذ مرتين بالخطأ يرفض من أول سطر بلا أثر.
- الترقيات **إضافة فقط**: لا تعدّل بيانات قائمة. `complete_sale` يُعاد تعريفه مع إبقاء استدعاء الكود الحالي (3 معاملات) صالحاً.
- **الكود الحالي (main) يعمل على القاعدة المرقّاة** (بيع، إرجاع، استبدال). لذلك لا عجلة بين الترقية والدمج.
- كل الميزات الجديدة **مطفأة افتراضياً**: الولاء غير مفعّل، لا عروض، ولا آجل لأي عميل حتى يُحدَّد حده.

**التوقيت المقترح:** خارج ساعات الذروة. الورديات المفتوحة لا تمنع الترقية (جُرّب ذلك)، لكن الأفضل ألا يكون هناك بيع جارٍ في نفس اللحظة.

---

## الخطوة 1 — نقطة استرجاع (Backup)

1. Supabase → **Database → Backups**:
   - **Pro:** تأكد أن آخر نسخة يومية بتاريخ اليوم. وإن كان **PITR** مفعّلاً، سجّل الوقت الحالي (UTC) كنقطة استرجاع.
   - **Free:** لا توجد نسخ قابلة للاسترجاع. خذ نسخة يدوية من جهازك:
     ```bash
     # Project Settings → Database → Connection string (Session pooler)
     pg_dump "postgresql://postgres.[ref]:[password]@...pooler.supabase.com:5432/postgres" \
       --schema=public --schema=auth --no-owner -Fc -f sanad-before-pr7.dump
     ls -lh sanad-before-pr7.dump   # يجب أن يكون أكبر من صفر
     ```
2. **لا تكمل قبل وجود نسخة مؤكدة.**

---

## الخطوة 2 — الفحص المسبق (قراءة فقط)

يتأكد أن المتطلبات موجودة (0006، 0007، 0008) وأن ترقيات #7 لم تُنفَّذ من قبل.

```sql
-- المرحلة 1 — الفحص المسبق (قراءة فقط)
select 'pg_version' as check_name, current_setting('server_version') as value, '15 أو أعلى' as expected
union all select 'prereq_0006_shifts', (to_regclass('public.shifts') is not null)::text, 'true'
union all select 'prereq_0007_expenses', (to_regclass('public.expenses') is not null)::text, 'true'
union all select 'prereq_0008_advisor', (to_regprocedure('public.purchase_advisor(integer,integer,integer)') is not null)::text, 'true'
union all select 'not_applied_0009', (to_regclass('public.customer_accounts') is null)::text, 'true'
union all select 'not_applied_0010', (to_regclass('public.promotions') is null)::text, 'true'
union all select 'not_applied_0011', (not exists (select 1 from information_schema.columns
            where table_schema = 'public' and table_name = 'sales' and column_name = 'public_token'))::text, 'true'
union all select 'not_applied_0012', (to_regprocedure('public.customer_profile(uuid)') is null)::text, 'true'
union all select 'pr8_not_applied', (to_regclass('public.locations') is null)::text, 'true'
union all select 'complete_sale_count', (select count(*)::text from pg_proc
            where proname = 'complete_sale' and pronamespace = 'public'::regnamespace), '1'
union all select 'payment_methods', (select string_agg(e.enumlabel, ',' order by e.enumsortorder)
            from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'payment_method'), 'لا تحتوي on_account'
union all select 'open_shifts', (select count(*)::text from public.shifts where status = 'open'), 'يُفضّل 0 (ليس شرطاً)';
```

**المتوقع:** كل الأسطر `true`، و`complete_sale_count = 1`، و`payment_methods` = `cash,card,transfer,exchange_credit`.
- إن كان `prereq_0008_advisor = false`: نفّذ أولاً `upgrades/0008_purchase_advisor.sql` (موجود في main)، ثم أعد هذا الفحص.
- إن كان أي `not_applied_* = false`: **توقف** وأرسل الناتج (معناه أن جزءاً نُفّذ سابقاً).

---

## الخطوة 3 — لقطة «قبل» (قراءة فقط)

نفّذ واحفظ الناتج (Export CSV أو نسخ الجدول):

```sql
-- لقطة البيانات (قراءة فقط) — نفّذها قبل الترقية وبعدها واحفظ الناتج
select 'products' as k, count(*)::text as v from public.products
union all select 'variants', count(*)::text from public.product_variants
union all select 'stock_total', coalesce(sum(stock_qty), 0)::text from public.product_variants
union all select 'stock_hash', md5(coalesce(string_agg(id::text || ':' || stock_qty, ',' order by id), '')) from public.product_variants
union all select 'costs_hash', md5(coalesce(string_agg(variant_id::text || ':' || cost_price, ',' order by variant_id), '')) from public.variant_costs
union all select 'sales', count(*)::text from public.sales
union all select 'sales_total', coalesce(sum(total), 0)::text from public.sales
union all select 'sales_hash', md5(coalesce(string_agg(id::text || ':' || total || ':' || returned_amount || ':' || status, ',' order by id), '')) from public.sales
union all select 'sale_items', count(*)::text from public.sale_items
union all select 'payments_total', coalesce(sum(amount), 0)::text from public.sale_payments
union all select 'returns', count(*)::text || ' / ' || coalesce(sum(total), 0) from public.returns
union all select 'customers', count(*)::text from public.customers
union all select 'customers_hash', md5(coalesce(string_agg(id::text || ':' || name || ':' || coalesce(phone, ''), ',' order by id), '')) from public.customers
union all select 'stock_movements', count(*)::text from public.stock_movements
union all select 'purchase_orders', count(*)::text || ' / ' || coalesce(sum(total), 0) from public.purchase_orders
union all select 'shifts', count(*)::text || ' (open ' || count(*) filter (where status = 'open') || ')' from public.shifts
union all select 'shift_cash_movements', count(*)::text || ' / ' || coalesce(sum(amount), 0) from public.shift_cash_movements
union all select 'expenses', count(*)::text || ' / ' || coalesce(sum(amount), 0) from public.expenses
union all select 'profiles', count(*)::text from public.profiles
order by 1;
```

---

## الخطوة 4 — الترقيات، كل ملف في استعلام منفصل وبالترتيب

الملفات من `pos-app/supabase/setup/upgrades/` في فرع PR #7. افتح الملف، انسخ **كامل** محتواه في نافذة SQL Editor جديدة، ثم Run.
النتيجة المتوقعة للملف نفسه: `Success. No rows returned`. بعده مباشرة نفّذ استعلام التحقق الخاص به وقارن.

### 4.1 — `0009_customer_accounts.sql` (حسابات العملاء، الآجل، التحصيل، النقاط)
```sql
-- تحقق 0009
select
  (select count(*) from information_schema.tables where table_schema = 'public'
     and table_name in ('customer_accounts', 'customer_ledger', 'customer_payments', 'loyalty_ledger')) as tables_expect_4,
  (select count(*) from pg_enum e join pg_type t on t.oid = e.enumtypid
     where (t.typname = 'payment_method' and e.enumlabel = 'on_account')
        or (t.typname = 'refund_method' and e.enumlabel = 'account')) as new_methods_expect_2,
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
     ('record_customer_payment', 'void_customer_payment', 'customer_statement', 'receivables_report',
      'set_credit_limit', 'adjust_loyalty')) as functions_expect_6,
  (select loyalty_enabled from public.store_settings where id = 1) as loyalty_expect_false,
  (select allow_cashier_credit from public.store_settings where id = 1) as cashier_credit_expect_false,
  (select count(*) from public.customer_ledger) as ledger_rows_expect_0,
  has_table_privilege('anon', 'public.customer_ledger', 'select') as anon_read_expect_false;
```
**المتوقع:** `4 | 2 | 6 | false | false | 0 | false`

### 4.2 — `0010_promotions_reservations.sql` (العروض، الحجوزات)
```sql
-- تحقق 0010
select
  (select count(*) from information_schema.tables where table_schema = 'public'
     and table_name in ('promotions', 'reservations', 'reservation_items')) as tables_expect_3,
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
     ('create_reservation', 'cancel_reservation', 'extend_reservation', 'reserved_quantities')) as functions_expect_4,
  (select count(*) from public.promotions) as promotions_expect_0,
  (select count(*) from public.reservations) as reservations_expect_0,
  has_table_privilege('anon', 'public.promotions', 'select') as anon_read_expect_false;
```
**المتوقع:** `3 | 4 | 0 | 0 | false`

### 4.3 — `0011_sales_v2.sql` (البيع 2.0، رابط الفاتورة، المرتجع إلى الحساب)
```sql
-- تحقق 0011
select
  (select count(*) from pg_proc where proname = 'complete_sale' and pronamespace = 'public'::regnamespace) as complete_sale_expect_1,
  (select pronargs from pg_proc where proname = 'complete_sale' and pronamespace = 'public'::regnamespace) as args_expect_9,
  (select count(*) from public.sales where public_token is null) as sales_without_token_expect_0,
  (select count(*) from public.sales where client_ref is not null or promo_discount <> 0 or loyalty_discount <> 0) as changed_sales_expect_0,
  (select count(*) from pg_trigger where tgname = 'returns_posted' and not tgisinternal) as return_trigger_expect_1,
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
     ('price_cart', 'public_receipt', 'resolve_invoice_ref', 'sale_return_context')) as functions_expect_4,
  (to_regclass('public.message_log') is not null) as message_log_expect_true,
  has_function_privilege('anon', 'public.public_receipt(text)', 'execute') as public_receipt_anon_expect_true,
  has_table_privilege('anon', 'public.sales', 'select') as anon_sales_expect_false;
```
**المتوقع:** `1 | 9 | 0 | 0 | 1 | 4 | true | true | false`
(`public_receipt_anon = true` مقصود: رابط الفاتورة العام يعمل بدون دخول ويعرض بيانات الفاتورة فقط)

### 4.4 — `0012_customer_insights.sql` (ملف العميل والتحليلات — قراءة فقط)
```sql
-- تحقق 0012
select
  (to_regprocedure('public.customer_profile(uuid)') is not null) as profile_expect_true,
  (to_regprocedure('public.customer_analytics(date,date)') is not null) as analytics_expect_true,
  has_function_privilege('anon', 'public.customer_profile(uuid)', 'execute') as anon_profile_expect_false;
```
**المتوقع:** `true | true | false`

---

## الخطوة 5 — لقطة «بعد» والفحص النهائي (قراءة فقط)

1. نفّذ **نفس** استعلام الخطوة 3. **يجب أن تتطابق كل القيم** مع لقطة «قبل» (الترقيات لا تغيّر أي بيانات).
2. ثم:
```sql
-- فحص نهائي بعد 0012 (قراءة فقط)
select
  (select count(*) from public.customer_accounts a
    where a.account_balance <> coalesce((select sum(l.debit - l.credit) from public.customer_ledger l where l.customer_id = a.customer_id), 0)) as balance_mismatch_expect_0,
  (select count(*) from public.customer_accounts a
    where a.loyalty_points <> coalesce((select sum(l.points) from public.loyalty_ledger l where l.customer_id = a.customer_id), 0)) as points_mismatch_expect_0,
  (select count(*) from public.product_variants where stock_qty < 0) as negative_stock_before_equals_after;
```
**المتوقع:** `0 | 0 |` نفس عدد الأرصدة السالبة في لقطة «قبل» (غالباً 0).

عند هذه النقطة: القاعدة مرقّاة والتطبيق الحالي يعمل كما هو. **أرسل لي النتائج وانتظر الموافقة على الدمج.**

---

## الخطوة 6 — دمج PR #7 (بعد موافقتك فقط)

1. أدمج PR #7 من GitHub (أو أطلب مني الدمج بعد مراجعة النتائج).
2. انتظر Vercel حتى تصبح الحالة **Ready**.
3. حدّث الصفحة في المتصفح (Ctrl+F5) على كل جهاز كاشير.

---

## الخطوة 7 — Smoke Test بعد الدمج (10 دقائق)

⚠️ عمليات حقيقية تظهر في التقارير. استخدم صنفاً رخيصاً وعميل اختبار (مثلاً «عميل اختبار» برقم جوالك)، ثم أرجع ما بعته.

| # | الاختبار | المتوقع |
|---|---|---|
| 1 | تسجيل الدخول (مالك) ← لوحة التحكم | تظهر بلا أخطاء |
| 2 | الورديات ← فتح وردية | مفتوحة |
| 3 | نقطة البيع ← عميل الاختبار ← قطعة واحدة ← نقداً | الفاتورة فيها **QR الاسترجاع** وزر **واتساب** (رابط `wa.me/966…`) |
| 4 | افتح رابط الفاتورة العام في نافذة خاصة (بدون دخول) | تظهر الفاتورة **بدون** بيانات العميل |
| 5 | المرتجعات ← امسح QR الفاتورة (أو الصق الرابط) ← إرجاع القطعة نقداً | الفاتورة تُسترجع، المخزون +1 |
| 6 | العملاء ← عميل الاختبار | الملف يعرض المشتريات والمرتجع |
| 7 | (مدير) حدّد حد ائتمان 100 لعميل الاختبار ← بيع قطعة: جزء نقداً والباقي «آجل» | الرصيد المستحق على العميل = الجزء الآجل |
| 8 | ملف العميل ← سند تحصيل من الدرج بكامل الرصيد | الرصيد 0، والكشف فيه البيع والتحصيل |
| 9 | فتح صفحات العروض والحجوزات وتحليلات العملاء (بدون إنشاء) | تُحمَّل بلا أخطاء |
| 10 | إرجاع قطعة البند 7، ثم إغلاق الوردية | تقرير Z: التحصيل ظاهر كإيداع، والنقد المتوقع مطابق |

بعدها أعد حد ائتمان عميل الاختبار إلى فارغ، ونفّذ الفحص النهائي من الخطوة 5.2 (يجب `0 | 0`).

---

## خطة التراجع
- **فشل ملف أثناء التنفيذ:** لا يتغير شيء (معاملة واحدة). توقف وأرسل الخطأ.
- **ظهرت مشكلة بعد الدمج:** أعد نشر النسخة السابقة من Vercel (**Deployments → Promote** على آخر نشر قبل الدمج). الكود القديم يعمل على القاعدة المرقّاة، فلا حاجة للمساس بالقاعدة.
- **استرجاع القاعدة من النسخة الاحتياطية:** الملاذ الأخير فقط، لأنه يُضيع أي مبيعات بعد وقت النسخة.

---

## ما ترسله لي
1. تأكيد النسخة الاحتياطية (تاريخها أو اسم الملف وحجمه).
2. ناتج الفحص المسبق (الخطوة 2).
3. ناتج التحقق بعد كل ملف (4 أسطر).
4. لقطتا «قبل» و«بعد» + الفحص النهائي.
5. بعد الدمج: نتيجة كل بند في الـ Smoke Test (✓/✗ + صورة لأي خطأ).
