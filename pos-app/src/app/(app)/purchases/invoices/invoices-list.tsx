"use client";

import { Plus } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import { Badge, Button, Card, EmptyState, Loading, PageHeader, Select, Table } from "@/components/ui";
import { dateOnly, money } from "@/lib/format";
import { INVOICE_STATUS, TERMS_LABELS, type ApInvoiceStatus, type SupplierInvoice } from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";

type Row = SupplierInvoice & { supplier: { name: string } | null };

export function InvoicesList() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [status, setStatus] = useState<"" | ApInvoiceStatus | "open">("open");

  useEffect(() => {
    let q = supabase().from("supplier_invoices").select("*, supplier:suppliers(name)").neq("kind", "opening")
      .order("invoice_date", { ascending: false }).order("created_at", { ascending: false }).limit(300);
    if (status === "open") q = q.in("status", ["draft", "posted", "partially_paid"]);
    else if (status) q = q.eq("status", status);
    q.then(({ data }) => setRows((data ?? []) as Row[]));
  }, [status]);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="فواتير الموردين"
        subtitle="كل فاتورة تُطابق مع أمر الشراء والاستلام قبل ترحيلها إلى حساب المورد"
        actions={
          <Link href="/purchases/invoices/new">
            <Button>
              <Plus className="size-4" /> فاتورة مصروف (بدون أمر شراء)
            </Button>
          </Link>
        }
      />
      <div className="mb-3">
        <Select aria-label="الحالة" className="w-auto" value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
          <option value="open">المفتوحة (مسودة/مستحقة)</option>
          <option value="">الكل</option>
          {(Object.keys(INVOICE_STATUS) as ApInvoiceStatus[]).map((s) => (
            <option key={s} value={s}>
              {INVOICE_STATUS[s].label}
            </option>
          ))}
        </Select>
      </div>
      <Card>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد فواتير">سجّل فاتورة المورد من صفحة أمر الشراء بعد الاستلام.</EmptyState>
        ) : (
          <Table>
            <thead>
              <tr>
                <th>المستند</th>
                <th>المورد</th>
                <th>فاتورة المورد</th>
                <th>التاريخ</th>
                <th>الاستحقاق</th>
                <th>السداد</th>
                <th>الإجمالي</th>
                <th>المتبقي</th>
                <th>الحالة</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((i) => (
                <tr key={i.id}>
                  <td>
                    <Link href={`/purchases/invoices/${i.id}`} className="ltr-nums font-medium text-brand-700 hover:underline">
                      {i.doc_no}
                    </Link>
                    {i.kind === "expense" && <span className="block text-xs text-slate-500">مصروف</span>}
                  </td>
                  <td>{i.supplier?.name}</td>
                  <td className="ltr-nums">{i.supplier_invoice_no ?? "-"}</td>
                  <td className="ltr-nums">{dateOnly(i.invoice_date)}</td>
                  <td className="ltr-nums">{i.due_date ? dateOnly(i.due_date) : "-"}</td>
                  <td>{TERMS_LABELS[i.payment_terms]}</td>
                  <td>{money(i.total)}</td>
                  <td className="font-semibold">{i.status === "void" ? "-" : money(Number(i.total) - Number(i.settled_amount))}</td>
                  <td>
                    <Badge tone={INVOICE_STATUS[i.status].tone}>{INVOICE_STATUS[i.status].label}</Badge>
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}
