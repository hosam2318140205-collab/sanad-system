"use client";

import { useEffect, useState } from "react";
import { Badge, Button, Card, EmptyState, Input, Loading, Modal, PageHeader, Select, Table } from "@/components/ui";
import { dateTime, isoDay } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { AuditEntry } from "@/lib/types";

const TABLES: Record<string, string> = {
  store_settings: "الإعدادات",
  profiles: "المستخدمون",
  categories: "التصنيفات",
  products: "المنتجات",
  product_variants: "الأصناف",
  variant_costs: "التكلفة",
  customers: "العملاء",
  suppliers: "الموردون",
  sales: "الفواتير",
  sale_payments: "المدفوعات",
  returns: "المرتجعات",
  purchase_orders: "أوامر الشراء",
  purchase_items: "بنود الشراء",
  stock_counts: "الجرد",
};

const ACTIONS = {
  INSERT: { label: "إضافة", tone: "green" as const },
  UPDATE: { label: "تعديل", tone: "blue" as const },
  DELETE: { label: "حذف", tone: "red" as const },
};

type Row = AuditEntry & { actor: { full_name: string } | null };

function summary(e: AuditEntry): string {
  const d = (e.new_data ?? e.old_data ?? {}) as Record<string, unknown>;
  return String(d.invoice_no ?? d.return_no ?? d.po_no ?? d.count_no ?? d.name ?? d.sku ?? d.full_name ?? d.store_name ?? e.record_id ?? "");
}

export function AuditScreen() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [table, setTable] = useState("");
  const [action, setAction] = useState("");
  const [day, setDay] = useState("");
  const [detail, setDetail] = useState<Row | null>(null);
  const [limit, setLimit] = useState(100);

  useEffect(() => {
    let req = supabase()
      .from("audit_log")
      .select("*, actor:profiles(full_name)")
      .order("created_at", { ascending: false })
      .limit(limit);
    if (table) req = req.eq("table_name", table);
    if (action) req = req.eq("action", action);
    if (day) req = req.gte("created_at", `${day}T00:00:00+03:00`).lte("created_at", `${day}T23:59:59.999+03:00`);
    req.then(({ data }) => setRows((data ?? []) as Row[]));
  }, [table, action, day, limit]);

  return (
    <div className="p-4 md:p-6">
      <PageHeader title="سجل التدقيق" subtitle="كل إضافة أو تعديل أو حذف في النظام مع المستخدم والوقت" />
      <Card>
        <div className="flex flex-wrap gap-2 border-b border-slate-100 p-3">
          <Select className="w-auto" value={table} onChange={(e) => setTable(e.target.value)}>
            <option value="">كل الجداول</option>
            {Object.entries(TABLES).map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
          </Select>
          <Select className="w-auto" value={action} onChange={(e) => setAction(e.target.value)}>
            <option value="">كل العمليات</option>
            {Object.entries(ACTIONS).map(([k, v]) => (
              <option key={k} value={k}>
                {v.label}
              </option>
            ))}
          </Select>
          <Input type="date" className="w-auto" value={day} max={isoDay()} onChange={(e) => setDay(e.target.value)} />
        </div>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد سجلات" />
        ) : (
          <>
            <Table>
              <thead>
                <tr>
                  <th>الوقت</th>
                  <th>المستخدم</th>
                  <th>العملية</th>
                  <th>الجدول</th>
                  <th>السجل</th>
                  <th>الحقول المعدلة</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className="cursor-pointer" onClick={() => setDetail(r)}>
                    <td className="ltr-nums text-slate-600">{dateTime(r.created_at)}</td>
                    <td>{r.actor?.full_name ?? "النظام"}</td>
                    <td>
                      <Badge tone={ACTIONS[r.action].tone}>{ACTIONS[r.action].label}</Badge>
                    </td>
                    <td>{TABLES[r.table_name] ?? r.table_name}</td>
                    <td className="max-w-52 truncate">{summary(r)}</td>
                    <td className="max-w-60 truncate text-xs text-slate-500" dir="ltr">
                      {r.changed_fields?.join(", ") ?? ""}
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
            {rows.length >= limit && (
              <div className="p-3 text-center">
                <Button variant="outline" size="sm" onClick={() => setLimit((l) => l + 100)}>
                  عرض المزيد
                </Button>
              </div>
            )}
          </>
        )}
      </Card>

      <Modal open={!!detail} onClose={() => setDetail(null)} title="تفاصيل السجل" size="lg">
        {detail && (
          <div className="grid gap-3 md:grid-cols-2" dir="ltr">
            <div>
              <p className="mb-1 text-sm font-semibold">Before</p>
              <pre className="max-h-96 overflow-auto rounded-lg bg-slate-50 p-3 text-xs">{JSON.stringify(detail.old_data, null, 2)}</pre>
            </div>
            <div>
              <p className="mb-1 text-sm font-semibold">After</p>
              <pre className="max-h-96 overflow-auto rounded-lg bg-slate-50 p-3 text-xs">{JSON.stringify(detail.new_data, null, 2)}</pre>
            </div>
          </div>
        )}
      </Modal>
    </div>
  );
}
