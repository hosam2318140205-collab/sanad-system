"use client";

import { ArrowRight, Printer, Undo2 } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import type { ReceiptData } from "@/components/receipt";
import { ReceiptModal } from "@/components/receipt-modal";
import { Badge, Button, Card, Loading, PageHeader, Table, useToast } from "@/components/ui";
import { PAYMENT_LABELS, REFUND_LABELS, SALE_STATUS_LABELS, dateTime, errorMessage, money } from "@/lib/format";
import { loadReceipt } from "@/lib/sales";
import { supabase } from "@/lib/supabase/client";
import type { ReturnRecord } from "@/lib/types";

export function SaleDetail({ id }: { id: string }) {
  const toast = useToast();
  const [data, setData] = useState<ReceiptData | null>(null);
  const [returns, setReturns] = useState<ReturnRecord[]>([]);
  const [showReceipt, setShowReceipt] = useState(false);

  useEffect(() => {
    loadReceipt(id)
      .then(setData)
      .catch((e) => toast(errorMessage(e), "error"));
    supabase()
      .from("returns")
      .select("*")
      .eq("sale_id", id)
      .order("created_at")
      .then(({ data }) => setReturns((data ?? []) as ReturnRecord[]));
  }, [id, toast]);

  if (!data) return <Loading />;
  const { sale, items, payments } = data;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={`فاتورة ${sale.invoice_no}`}
        subtitle={dateTime(sale.created_at)}
        actions={
          <>
            <Link href="/sales">
              <Button variant="ghost">
                <ArrowRight className="size-4" /> رجوع
              </Button>
            </Link>
            {sale.status !== "returned" && (
              <Link href={`/returns?invoice=${encodeURIComponent(sale.invoice_no)}`}>
                <Button variant="outline">
                  <Undo2 className="size-4" /> إرجاع / استبدال
                </Button>
              </Link>
            )}
            <Button onClick={() => setShowReceipt(true)}>
              <Printer className="size-4" /> طباعة
            </Button>
          </>
        }
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <Table>
            <thead>
              <tr>
                <th>الصنف</th>
                <th>الكمية</th>
                <th>السعر</th>
                <th>الخصم</th>
                <th>الضريبة</th>
                <th>الإجمالي</th>
                <th>مرتجع</th>
              </tr>
            </thead>
            <tbody>
              {items.map((i) => (
                <tr key={i.id}>
                  <td>
                    <p className="font-medium">{i.product_name}</p>
                    <p className="text-xs text-slate-500">
                      {i.variant_label} · <span dir="ltr">{i.sku}</span>
                    </p>
                  </td>
                  <td>{i.qty}</td>
                  <td>{money(i.unit_price)}</td>
                  <td>{Number(i.line_discount) > 0 ? money(i.line_discount) : "-"}</td>
                  <td>{money(i.vat_amount)}</td>
                  <td className="font-semibold">{money(i.line_total)}</td>
                  <td>{i.returned_qty > 0 ? <Badge tone="red">{i.returned_qty}</Badge> : "-"}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>

        <div className="space-y-4">
          <Card className="space-y-2 p-4 text-sm">
            <Line label="الحالة" value={SALE_STATUS_LABELS[sale.status]} />
            <Line label="العميل" value={data.customerName ?? "عميل نقدي"} />
            <Line label="الكاشير" value={data.cashierName ?? "-"} />
            <hr className="border-slate-100" />
            <Line label="الخصم" value={money(sale.discount_total)} />
            <Line label="قبل الضريبة" value={money(sale.subtotal)} />
            <Line label={`الضريبة ${Number(sale.vat_rate)}%`} value={money(sale.vat_amount)} />
            <Line label="الإجمالي" value={money(sale.total)} bold />
            {Number(sale.returned_amount) > 0 && <Line label="المرتجع" value={money(sale.returned_amount)} />}
          </Card>
          <Card className="space-y-2 p-4 text-sm">
            <p className="font-semibold">المدفوعات</p>
            {payments.map((p) => (
              <Line key={p.id} label={`${PAYMENT_LABELS[p.method]}${p.reference ? ` (${p.reference})` : ""}`} value={money(p.amount)} />
            ))}
            {Number(sale.change_amount) > 0 && <Line label="الباقي للعميل" value={money(sale.change_amount)} />}
          </Card>
          {returns.length > 0 && (
            <Card className="space-y-2 p-4 text-sm">
              <p className="font-semibold">المرتجعات</p>
              {returns.map((r) => (
                <div key={r.id} className="flex justify-between">
                  <span>
                    {r.return_no} · {REFUND_LABELS[r.refund_method]}
                  </span>
                  <span className="font-medium text-red-600">{money(r.total)}</span>
                </div>
              ))}
            </Card>
          )}
        </div>
      </div>

      {showReceipt && <ReceiptModal data={data} title="نسخة الفاتورة" onClose={() => setShowReceipt(false)} />}
    </div>
  );
}

function Line({ label, value, bold }: { label: string; value: string; bold?: boolean }) {
  return (
    <div className={`flex justify-between ${bold ? "text-base font-bold" : ""}`}>
      <span className="text-slate-600">{label}</span>
      <span>{value}</span>
    </div>
  );
}
