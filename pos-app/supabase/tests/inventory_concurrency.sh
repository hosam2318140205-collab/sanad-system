#!/usr/bin/env bash
# سباقات حقيقية بين جلستين PostgreSQL منفصلتين على قاعدة اختبار مؤقتة (تُنفَّذ من test-db.sh بعد باقي الاختبارات).
# الجلسة الأولى تنفّذ العملية وتُبقي المعاملة مفتوحة ثانية واحدة، والثانية تبدأ أثناء ذلك فتنتظر القفل.
#   تحويلان يتجاوزان الرصيد، شحن مزدوج، استلام مزدوج، مسح مكرر بنفس المرجع، جهازان يعدّان نفس SKU،
#   بيع آخر قطعة من كاشيرين، طلب تحويل وتسوية بنفس المرجع — ثم القيد وعدم وجود رصيد سالب.
set -euo pipefail
T="${1:?database url}"

OWNER=00000000-0000-0000-0000-0000000000e1
CASH1=00000000-0000-0000-0000-0000000000e2
CASH2=00000000-0000-0000-0000-0000000000e3
V=00000000-0000-0000-0000-0000000000e5   # 10 في الرئيسي
W=00000000-0000-0000-0000-0000000000e6   # قطعة واحدة في الفرع

sql() { psql "$T" -X -q -At -v ON_ERROR_STOP=1 "$@"; }
# as <user> <sql> [sleep]: معاملة واحدة بصلاحية المستخدم، تُمسك أقفالها <sleep> ثانية قبل commit
as() {
  sql <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$1', true) \\g /dev/null
$2;
select pg_sleep(${3:-0}) \\g /dev/null
commit;
SQL
}
# race <user1> <sql1> <user2> <sql2>: يطبع ناتج الثانية (أو رسالة خطئها) بعد انتهاء الاثنتين
race() {
  local out1; out1=$(mktemp)
  as "$1" "$2" 1 >"$out1" 2>&1 &
  local pid=$!
  sleep 0.3
  local r2; r2=$(as "$3" "$4" 0 2>&1 || true)
  wait "$pid" || { echo "first session failed: $(cat "$out1")" >&2; exit 1; }
  rm -f "$out1"
  printf '%s' "$r2"
}
check() { # check <sql returning boolean> <message>
  if [ "$(sql -c "select $1")" != "t" ]; then echo "✗ $2" >&2; exit 1; fi
  echo "  ✓ $2"
}
loc() { echo "(select id from public.locations where code = '$1')"; }
qty() { echo "coalesce((select qty from public.location_stock where location_id = $(loc "$1") and variant_id = '$2'), 0)"; }

sql <<SQL
insert into auth.users (id, email) values ('$OWNER', 'owner@race.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('$CASH1', 'c1@race.test', '{"role":"cashier"}'), ('$CASH2', 'c2@race.test', '{"role":"cashier"}');
insert into public.products (id, name, base_price) values ('00000000-0000-0000-0000-0000000000e4', 'سباق', 50);
insert into public.product_variants (id, product_id, sku, barcode, size, stock_qty) values
  ('$V', '00000000-0000-0000-0000-0000000000e4', 'RACE-V', '2999000000011', 'M', 10),
  ('$W', '00000000-0000-0000-0000-0000000000e4', 'RACE-W', '2999000000028', 'L', 1);
insert into public.locations (code, name, kind) values ('RB', 'فرع السباق', 'store');
SQL
as $OWNER "select public.set_staff_location('$CASH1', $(loc RB)); select public.set_staff_location('$CASH2', $(loc RB));
  select public.approve_transfer(public.request_transfer($(loc MAIN), $(loc RB), '[{\"variant_id\":\"$W\",\"qty\":1}]'))" >/dev/null
TW=$(sql -c "select id from public.transfers where to_location = $(loc RB)")
as $OWNER "select public.ship_transfer('$TW')" >/dev/null
as $CASH1 "select public.receive_transfer('$TW'); select public.open_shift(0)" >/dev/null
as $CASH2 "select public.open_shift(0)" >/dev/null
TA=$(as $OWNER "select public.request_transfer($(loc MAIN), $(loc RB), '[{\"variant_id\":\"$V\",\"qty\":7}]')")
TB=$(as $OWNER "select public.request_transfer($(loc MAIN), $(loc RB), '[{\"variant_id\":\"$V\",\"qty\":7}]')")

echo "▶ اعتمادان متزامنان (7 + 7 من رصيد 10)"
r=$(race $OWNER "select public.approve_transfer('$TA')" $OWNER "select public.approve_transfer('$TB')")
[[ "$r" == *"المتاح في المصدر"* ]] || { echo "✗ second approval should fail: $r" >&2; exit 1; }
check "(select status from public.transfers where id = '$TB') = 'requested'" "الثاني رُفض ولم يُحجز"

echo "▶ شحن مزدوج لنفس التحويل"
r=$(race $OWNER "select public.ship_transfer('$TA', null, false, 'aaaaaaaa-0000-0000-0000-000000000001')" \
         $OWNER "select public.ship_transfer('$TA', null, false, 'aaaaaaaa-0000-0000-0000-000000000002')")
[[ "$r" == *"لا توجد كمي"* || "$r" == *"حالة"* ]] || { echo "✗ second ship should fail: $r" >&2; exit 1; }
check "$(qty MAIN $V) = 3 and $(qty TRANSIT $V) = 7" "شُحنت 7 مرة واحدة فقط"

echo "▶ استلام مزدوج (بمرجعين مختلفين)"
r=$(race $CASH1 "select public.receive_transfer('$TA', null, true, 'aaaaaaaa-0000-0000-0000-000000000003')" \
         $CASH2 "select public.receive_transfer('$TA', null, true, 'aaaaaaaa-0000-0000-0000-000000000004')")
[[ "$r" == *"لا توجد كمي"* || "$r" == *"حالة"* ]] || { echo "✗ second receive should fail: $r" >&2; exit 1; }
check "$(qty RB $V) = 7 and $(qty TRANSIT $V) = 0" "استُلمت 7 مرة واحدة فقط"

echo "▶ بيع آخر قطعة من كاشيرين في نفس اللحظة"
SALE="select public.complete_sale('[{\"variant_id\":\"$W\",\"qty\":1}]', '[{\"method\":\"cash\",\"amount\":50}]')"
r=$(race $CASH1 "$SALE" $CASH2 "$SALE")
[[ "$r" == *"غير متوفر"* || "$r" == *"المتوفر"* || "$r" == *"المتاح"* ]] || { echo "✗ second sale should fail: $r" >&2; exit 1; }
check "$(qty RB $W) = 0 and (select stock_qty from public.product_variants where id = '$W') = 0" "بيعت مرة واحدة ولا رصيد سالب"

echo "▶ نفس طلب التحويل بنفس المرجع من جلستين"
REQ="select public.request_transfer($(loc RB), $(loc MAIN), '[{\"variant_id\":\"$V\",\"qty\":1}]', null, 'aaaaaaaa-0000-0000-0000-000000000005')"
r=$(race $CASH1 "$REQ" $CASH1 "$REQ")
check "(select count(*) = 1 and bool_and(id = '$r') from public.transfers where client_ref = 'aaaaaaaa-0000-0000-0000-000000000005')" "طلب واحد وأعيد نفس الرقم"

echo "▶ تسوية بنفس المرجع من جلستين"
ADJ="select public.adjust_location_stock($(loc MAIN), '$V', 2, 'وجدت', 'aaaaaaaa-0000-0000-0000-000000000006')"
race $OWNER "$ADJ" $OWNER "$ADJ" >/dev/null
check "$(qty MAIN $V) = 5" "طُبقت مرة واحدة"

echo "▶ الجرد: نفس المسحة من جلستين، وجهازان يعدّان نفس SKU"
C=$(as $OWNER "select public.start_location_count($(loc RB))")
SCAN="select public.record_count_scan('$C', 'RACE-V', 1, 'aaaaaaaa-0000-0000-0000-000000000007')"
r=$(race $CASH1 "$SCAN" $CASH1 "$SCAN")
[[ "$r" == *'"duplicate": true'* ]] || { echo "✗ duplicate scan not detected: $r" >&2; exit 1; }
race $CASH1 "select public.record_count_scan('$C', '2999000000011', 2, 'aaaaaaaa-0000-0000-0000-000000000008')" \
     $CASH2 "select public.record_count_scan('$C', 'race-v', 4, 'aaaaaaaa-0000-0000-0000-000000000009')" >/dev/null
check "(select counted_qty = 7 from public.stock_count_items where count_id = '$C' and variant_id = '$V')
       and (select count(*) = 3 from public.stock_count_scans where count_id = '$C')" "المعدود 1 + 2 + 4 = 7 بلا تكرار"
echo "▶ إرسال الجرد أثناء مسحة جارية"
r=$(race $CASH2 "select public.record_count_scan('$C', 'RACE-V', 1, 'aaaaaaaa-0000-0000-0000-00000000000a')" \
         $CASH1 "select public.submit_count('$C')")
check "(select status = 'submitted' from public.stock_counts where id = '$C')
       and (select counted_qty = 8 from public.stock_count_items where count_id = '$C' and variant_id = '$V')" "الإرسال انتظر المسحة"
r=$(as $CASH2 "select public.record_count_scan('$C', 'RACE-V', 1)" 2>&1 || true)
[[ "$r" == *"الجرد غير مفتوح"* ]] || { echo "✗ scan after submit should fail: $r" >&2; exit 1; }
[ "$(as $OWNER "select public.approve_count('$C')")" = 1 ] || { echo "✗ approve_count" >&2; exit 1; }
check "$(qty RB $V) = 8" "الاعتماد: الفرع 7 ← 8"

echo "▶ القيد النهائي"
check "not exists (select 1 from public.product_variants v where v.stock_qty <> coalesce((select sum(qty) from public.location_stock s where s.variant_id = v.id), 0))
       and not exists (select 1 from public.location_stock where qty < 0)
       and not exists (select 1 from public.product_variants where stock_qty < 0)" "مجموع المواقع = الإجمالي، ولا رصيد سالب"
