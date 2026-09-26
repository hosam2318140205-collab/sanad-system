#!/usr/bin/env bash
# سباقات حقيقية بين جلستين على حسابات الموردين والمشتريات (تُنفَّذ من test-db.sh بعد inventory_concurrency.sh).
#   دفعتان على نفس الفاتورة، نفس الدفعة بنفس المرجع، استلامان للمتبقي، ترحيل مزدوج، فاتورتان لنفس سطر الاستلام،
#   شحن مرتجع مقابل بيع آخر قطعة — ثم مطابقة الأرصدة للدفتر وقيد المواقع وعدم وجود رصيد سالب.
set -euo pipefail
T="${1:?database url}"

MGR1=00000000-0000-0000-0000-0000000000f7
MGR2=00000000-0000-0000-0000-0000000000f8
CASH=00000000-0000-0000-0000-0000000000f9
SUP=00000000-0000-0000-0000-000000000cf1
PO=00000000-0000-0000-0000-000000000cf2
V=00000000-0000-0000-0000-000000000cf3

sql() { psql "$T" -X -q -At -v ON_ERROR_STOP=1 "$@"; }
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
check() {
  if [ "$(sql -c "select $1")" != "t" ]; then echo "✗ $2" >&2; exit 1; fi
  echo "  ✓ $2"
}
expect() { # expect <output> <pattern> <message>
  [[ "$1" == *"$2"* ]] || { echo "✗ $3: $1" >&2; exit 1; }
}

sql <<SQL
insert into auth.users (id, email, raw_app_meta_data) values
  ('$MGR1', 'm1@sc.test', '{"role":"manager"}'), ('$MGR2', 'm2@sc.test', '{"role":"manager"}'), ('$CASH', 'c@sc.test', '{"role":"cashier"}');
insert into public.suppliers (id, name, payment_terms_days) values ('$SUP', 'مورد السباق', 30);
insert into public.products (id, name, base_price) values ('00000000-0000-0000-0000-000000000cf4', 'سباق مورد', 100);
insert into public.product_variants (id, product_id, sku, size) values ('$V', '00000000-0000-0000-0000-000000000cf4', 'SC-V', 'M');
insert into public.purchase_orders (id, po_no, supplier_id, status) values ('$PO', 'PO-SC-1', '$SUP', 'ordered');
insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost) values ('$PO', '$V', 10, 50);
SQL

echo "▶ استلامان متزامنان للمتبقي (10 من 10)"
r=$(race $MGR1 "select public.receive_goods('$PO', null, null, 'ad000000-0000-0000-0000-000000000001')" \
         $MGR2 "select public.receive_goods('$PO', null, null, 'ad000000-0000-0000-0000-000000000002')")
expect "$r" "بحالة" "second receipt should fail"
check "(select stock_qty = 10 from public.product_variants where id = '$V') and (select count(*) = 1 from public.goods_receipts where purchase_order_id = '$PO')" "استُلمت 10 مرة واحدة"

GRI=$(sql -c "select gi.id from public.goods_receipt_items gi join public.goods_receipts g on g.id = gi.receipt_id where g.purchase_order_id = '$PO'")
INV=$(as $MGR1 "select public.save_supplier_invoice(null, '$SUP', '$PO', 'SC-F1', current_date, null, 'credit', '[{\"receipt_item_id\":\"$GRI\",\"qty\":10}]')")
INV2=$(as $MGR1 "select public.save_supplier_invoice(null, '$SUP', null, 'SC-F2', current_date, null, 'credit', '[{\"receipt_item_id\":\"$GRI\",\"qty\":10}]')")

echo "▶ ترحيل مزدوج لنفس الفاتورة"
race $MGR1 "select public.post_supplier_invoice('$INV')" $MGR2 "select public.post_supplier_invoice('$INV')" >/dev/null
check "(select count(*) = 1 from public.supplier_ledger where source_id = '$INV') and (select balance = 575 from public.supplier_balances where supplier_id = '$SUP')" "قيد واحد، الرصيد 575"

echo "▶ فاتورة ثانية لنفس سطر الاستلام"
r=$(as $MGR2 "select public.post_supplier_invoice('$INV2')" 2>&1 || true)
expect "$r" "أكبر من المستلم" "second invoice for the same receipt line should fail"

echo "▶ دفعتان متزامنتان بكامل المستحق على نفس الفاتورة"
ALLOC="[{\"invoice_id\":\"$INV\",\"amount\":575}]"
r=$(race $MGR1 "select public.post_supplier_payment('$SUP', 575, 'cash', null, null, '$ALLOC', null, 'ad000000-0000-0000-0000-000000000003')" \
         $MGR2 "select public.post_supplier_payment('$SUP', 575, 'cash', null, null, '$ALLOC', null, 'ad000000-0000-0000-0000-000000000004')")
[[ "$r" == *"أكبر من المتبقي"* || "$r" == *"غير مفتوحة"* ]] || { echo "✗ second full payment should fail: $r" >&2; exit 1; }
check "(select settled_amount = 575 and status = 'paid' from public.supplier_invoices where id = '$INV')
       and (select count(*) = 1 from public.supplier_payments where supplier_id = '$SUP')" "سُددت مرة واحدة"

echo "▶ نفس الدفعة بنفس المرجع من جلستين (دفعة مقدمة)"
PAY="select public.post_supplier_payment('$SUP', 100, 'cash', null, null, null, 'مقدم', 'ad000000-0000-0000-0000-000000000005')"
race $MGR1 "$PAY" $MGR1 "$PAY" >/dev/null
check "(select count(*) = 2 from public.supplier_payments where supplier_id = '$SUP') and (select balance = -100 from public.supplier_balances where supplier_id = '$SUP')" "دفعة مقدمة واحدة، الرصيد −100"

echo "▶ شحن مرتجع مقابل بيع آخر 10 قطع في نفس اللحظة"
RT=$(as $MGR1 "select public.create_supplier_return('$SUP', (select id from public.locations where code = 'MAIN'), '[{\"receipt_item_id\":\"$GRI\",\"qty\":10}]', 'عيب')")
as $MGR2 "select public.approve_supplier_return('$RT')" >/dev/null
as $CASH "select public.open_shift(0)" >/dev/null
r=$(race $MGR1 "select public.ship_supplier_return('$RT')" \
         $CASH "select public.complete_sale('[{\"variant_id\":\"$V\",\"qty\":10}]', '[{\"method\":\"cash\",\"amount\":1000}]')")
[[ "$r" == *"المتوفر"* || "$r" == *"غير متوفرة"* || "$r" == *"المتاح"* ]] || { echo "✗ sale after return should fail: $r" >&2; exit 1; }
check "(select stock_qty = 0 from public.product_variants where id = '$V') and (select status = 'shipped' from public.supplier_returns where id = '$RT')" "خرجت مرة واحدة ولا رصيد سالب"

echo "▶ القيود النهائية"
check "not exists (select 1 from public.suppliers s where coalesce((select balance from public.supplier_balances b where b.supplier_id = s.id), 0)
                  <> coalesce((select sum(credit - debit) from public.supplier_ledger l where l.supplier_id = s.id), 0))" "الأرصدة = الدفتر لكل مورد"
check "not exists (select 1 from public.product_variants v where v.stock_qty <> coalesce((select sum(qty) from public.location_stock s where s.variant_id = v.id), 0))
       and not exists (select 1 from public.location_stock where qty < 0)" "مجموع المواقع = الإجمالي، ولا رصيد سالب"
