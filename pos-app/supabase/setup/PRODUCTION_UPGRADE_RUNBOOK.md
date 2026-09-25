# تجهيز Production — ترقية قاعدة البيانات قبل دمج PR #7

> كل ما في هذا الملف **قراءة فقط** ما عدا ملفات الترقية الخمسة. لا حذف، لا إعادة إنشاء، لا بيانات تجريبية.
> نفّذ من Supabase → **SQL Editor**. بعد أي خطأ: **توقف** وأرسل نص الخطأ كما هو.

---

## الخطوة 0 — نقطة استرجاع (Backup)

1. Supabase → **Database → Backups**:
   - الخطة المدفوعة (Pro): تأكد أن آخر نسخة يومية بتاريخ اليوم. وإن كان **PITR** مفعّلاً فسجّل الوقت الحالي (UTC) كنقطة استرجاع.
   - الخطة المجانية: لا توجد نسخ تلقائية قابلة للاسترجاع. خذ نسخة يدوية من جهازك:
     ```bash
     # من Project Settings → Database → Connection string (Session pooler)
     pg_dump "postgresql://postgres.[ref]:[password]@...pooler.supabase.com:5432/postgres" \
       --schema=public --schema=auth --no-owner -Fc -f sanad-before-0008.dump
     ```
     وتأكد أن الملف أكبر من صفر.
2. لا تكمل قبل وجود نسخة مؤكدة.

---

## الخطوة 1 — لقطة «قبل» (قراءة فقط)

نفّذ واحفظ الناتج (نسخ الجدول أو Export CSV):

```sql
select 'products' k, count(*)::text v from public.products
union all select 'variants', count(*)::text from public.product_variants
union all select 'stock_total', coalesce(sum(stock_qty),0)::text from public.product_variants
union all select 'stock_hash', md5(coalesce(string_agg(id::text||':'||stock_qty, ',' order by id),'')) from public.product_variants
union all select 'sales', count(*)::text from public.sales
union all select 'sales_total', coalesce(sum(total),0)::text from public.sales
union all select 'sales_hash', md5(coalesce(string_agg(id::text||':'||total||':'||returned_amount||':'||status, ',' order by id),'')) from public.sales
union all select 'sale_items', count(*)::text from public.sale_items
union all select 'payments_total', coalesce(sum(amount),0)::text from public.sale_payments
union all select 'returns', count(*)::text || ' / ' || coalesce(sum(total),0) from public.returns
union all select 'customers', count(*)::text from public.customers
union all select 'customers_hash', md5(coalesce(string_agg(id::text||':'||name||':'||coalesce(phone,''), ',' order by id),'')) from public.customers
union all select 'stock_movements', count(*)::text from public.stock_movements
union all select 'purchase_orders', count(*)::text || ' / ' || coalesce(sum(total),0) from public.purchase_orders
union all select 'shifts', count(*)::text from public.shifts
union all select 'expenses', count(*)::text || ' / ' || coalesce(sum(amount),0) from public.expenses;
```

---

## الخطوة 2 — الترقيات (كل ملف في استعلام منفصل، بالترتيب)

كل ملف معاملة واحدة: إما ينجح كله أو لا يتغير شيء. النتيجة المتوقعة: `Success. No rows returned`.
بعد كل ملف نفّذ استعلام التحقق الخاص به، والنتيجة يجب أن تطابق «المتوقع».

| # | الملف (من `pos-app/supabase/setup/upgrades/`) | استعلام التحقق | المتوقع |
|---|---|---|---|
| 1 | `0008_purchase_advisor.sql` | `select count(*) from pg_proc where proname in ('purchase_advisor','create_purchase_draft');` | `2` |
| 2 | `0009_customer_accounts.sql` | `select (select count(*) from information_schema.tables where table_schema='public' and table_name in ('customer_accounts','customer_ledger','loyalty_ledger','customer_payments')) t, (select loyalty_enabled from store_settings) loyalty;` | `t=4`, `loyalty=false` |
| 3 | `0010_promotions_reservations.sql` | `select (select count(*) from information_schema.tables where table_schema='public' and table_name in ('promotions','reservations','reservation_items')) t, (select count(*) from promotions) promos;` | `t=3`, `promos=0` |
| 4 | `0011_sales_v2.sql` | `select (select count(*) from pg_proc where proname='complete_sale') fn, (select max(pronargs) from pg_proc where proname='complete_sale') args, (select count(*) from sales where public_token is null) no_token, (select count(*) from pg_trigger where tgname='returns_posted') trg;` | `fn=1`, `args=9`, `no_token=0`, `trg=1` |
| 5 | `0012_customer_insights.sql` | `select count(*) from pg_proc where proname in ('customer_profile','customer_analytics');` | `2` |

بعد `0008` مباشرة: افتح `/advisor` في التطبيق (مالك) وتأكد أن الصفحة تُحمَّل دون خطأ.

---

## الخطوة 3 — لقطة «بعد» ومقارنة

نفّذ **نفس** استعلام الخطوة 1. يجب أن تتطابق كل القيم مع لقطة «قبل».
(إن نفّذت اختبارات الخطوة 4 قبلها فستتغير أعداد المبيعات والحركات بمقدار عمليات الاختبار فقط.)

---

## الخطوة 4 — اختبار الكود الحالي على Production (قبل دمج #7)

⚠️ هذه عمليات حقيقية تُسجَّل في التقارير وسجل التدقيق. استخدم صنفاً رخيصاً، ثم أرجعه في نفس اليوم.

| # | الاختبار | النتيجة المتوقعة |
|---|---|---|
| 1 | تسجيل الدخول (مالك) | لوحة التحكم تظهر |
| 2 | الورديات ← فتح وردية | الوردية مفتوحة |
| 3 | نقطة البيع ← بيع نقدي لقطعة واحدة | فاتورة حرارية + QR الهيئة، المخزون −1 |
| 4 | المرتجعات ← رقم الفاتورة ← إرجاع نقدي | إشعار دائن، المخزون +1 |
| 5 | بيع جديد ← إرجاع «استبدال (رصيد)» ← فاتورة بديلة برصيد الاستبدال | الرصيد مستخدم، الفرق مدفوع |
| 6 | المشتريات ← فتح أمر شراء سابق/إنشاء مسودة (لا تستلم) | الشاشة تعمل |
| 7 | مساعد الشراء ← «إعادة الحساب» + تبويب الراكد | الأرقام تظهر بلا خطأ |
| 8 | الورديات ← إغلاق الوردية | تقرير Z مطابق |

---

## ما ترسله لي بعد التنفيذ

1. تأكيد النسخة الاحتياطية (تاريخها أو اسم الملف).
2. ناتج استعلام التحقق لكل ترقية (5 أسطر).
3. لقطتا «قبل» و«بعد».
4. نتيجة كل اختبار في الخطوة 4 (✓/✗ + صورة لأي خطأ).

بعدها أراجع وأعطيك الحكم، ثم ننتظر أمرك بدمج PR #7.
