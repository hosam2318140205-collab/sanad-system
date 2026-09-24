"use client";

import { Plus } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import { Badge, Button, Card, EmptyState, Loading, PageHeader, Select, Table } from "@/components/ui";
import { PURCHASE_STATUS_LABELS, dateOnly, money } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { PurchaseOrder, PurchaseStatus } from "@/lib/types";

type Row = PurchaseOrder & { supplier: { name: string } | null };

const TONES: Record<PurchaseStatus, "slate" | "blue" | "green" | "red"> = {
  draft: "slate",
  ordered: "blue",
  received: "green",
  cancelled: "red",
};

export function PurchasesList() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [status, setStatus] = useState("");

  useEffect(() => {
    let req = supabase()
      .from("purchase_orders")
      .select("*, supplier:suppliers(name)")
      .order("created_at", { ascending: false })
      .limit(200);
    if (status) req = req.eq("status", status);
    req.then(({ data }) => setRows((data ?? []) as Row[]));
  }, [status]);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="المشتريات"
        subtitle="أوامر الشراء واستلام البضاعة من الموردين"
        actions={
          <Link href="/purchases/new">
            <Button>
              <Plus className="size-4" /> أمر شراء جديد
            </Button>
          </Link>
        }
      />
      <Card>
        <div className="border-b border-slate-100 p-3">
          <Select className="w-auto" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">كل الحالات</option>
            {Object.entries(PURCHASE_STATUS_LABELS).map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
          </Select>
        </div>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد أوامر شراء" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>رقم الأمر</th>
                <th>المورد</th>
                <th>فاتورة المورد</th>
                <th>التاريخ</th>
                <th>الإجمالي (شامل الضريبة)</th>
                <th>الحالة</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => (
                <tr key={p.id}>
                  <td>
                    <Link href={`/purchases/${p.id}`} className="font-medium text-brand-700 hover:underline">
                      {p.po_no}
                    </Link>
                  </td>
                  <td>{p.supplier?.name}</td>
                  <td className="ltr-nums">{p.supplier_invoice_no ?? "-"}</td>
                  <td className="ltr-nums">{dateOnly(p.created_at)}</td>
                  <td className="font-semibold">{money(p.total)}</td>
                  <td>
                    <Badge tone={TONES[p.status]}>{PURCHASE_STATUS_LABELS[p.status]}</Badge>
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
