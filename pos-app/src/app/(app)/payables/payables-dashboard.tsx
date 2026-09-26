"use client";

import { AlertTriangle, CalendarClock, PackageOpen, TrendingUp } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import { Badge, Card, EmptyState, Loading, PageHeader, Stat, Table, useToast } from "@/components/ui";
import { dateOnly, errorMessage, money } from "@/lib/format";
import type { AgingRow } from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";

interface Dashboard {
  due_this_week: number;
  overdue: { d1_30: number; d31_60: number; d61_90: number; d90_plus: number; total: number; not_due: number; open: number };
  unapplied_credits: number;
  received_not_invoiced: { value: number; lines: number; oldest_days: number };
  draft_invoices: number;
  purchases_by_month: Array<{ month: string; subtotal: number; vat: number }>;
  purchases_by_supplier: Array<{ supplier_id: string; name: string; subtotal: number }>;
  input_vat_this_month: number;
  cost_variance_this_month: number;
  price_alerts: Array<{ supplier_name: string; sku: string; unit_cost: number; change_pct: number; invoice_date: string }>;
  late_orders: Array<{ id: string; po_no: string; supplier_name: string; expected_at: string; days_late: number }>;
}

const n = (v: unknown) => Number(v ?? 0) || 0;

export function PayablesDashboard() {
  const toast = useToast();
  const [d, setD] = useState<Dashboard | null>(null);
  const [aging, setAging] = useState<AgingRow[]>([]);

  useEffect(() => {
    const db = supabase();
    Promise.all([db.rpc("purchasing_dashboard"), db.rpc("supplier_aging", { p_as_of: null })]).then(([a, b]) => {
      if (a.error) return toast(errorMessage(a.error), "error");
      setD(a.data as Dashboard);
      setAging(((b.data ?? []) as AgingRow[]).map((r) => ({
        ...r, not_due: n(r.not_due), d1_30: n(r.d1_30), d31_60: n(r.d31_60), d61_90: n(r.d61_90), d90_plus: n(r.d90_plus),
        total_open: n(r.total_open), unapplied: n(r.unapplied), net_balance: n(r.net_balance),
      })));
    });
  }, [toast]);

  if (!d) return <Loading />;
  const maxMonth = Math.max(1, ...d.purchases_by_month.map((m) => n(m.subtotal)));
  const overdueTotal = n(d.overdue.total);

  return (
    <div className="p-4 md:p-6">
      <PageHeader title="المستحقات والمشتريات" subtitle="ما علينا للموردين، ما تأخر، وما استُلم ولم تصل فاتورته" />

      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="إجمالي المستحق" value={money(d.overdue.open)} icon={<CalendarClock className="size-5" />} />
        <Stat label="مستحق هذا الأسبوع" value={money(d.due_this_week)} tone="amber" />
        <Stat label="متأخر" value={money(overdueTotal)} tone={overdueTotal > 0 ? "red" : "slate"} icon={<AlertTriangle className="size-5" />} />
        <Stat label="مستلم غير مفوتر" value={money(d.received_not_invoiced.value)}
              hint={d.received_not_invoiced.lines ? `${d.received_not_invoiced.lines} سطر · أقدمها ${d.received_not_invoiced.oldest_days} يوماً` : undefined}
              icon={<PackageOpen className="size-5" />} />
        <Stat label="أرصدة دائنة غير مطبقة" value={money(d.unapplied_credits)} tone="green" />
        <Stat label="ضريبة المدخلات هذا الشهر" value={money(d.input_vat_this_month)} />
        <Stat label="فرق تكلفة هذا الشهر" value={money(d.cost_variance_this_month)} hint="نصيب ما بيع قبل وصول الفاتورة/التكاليف"
              tone={n(d.cost_variance_this_month) > 0 ? "red" : "slate"} />
        <Stat label="فواتير مسودة" value={String(d.draft_invoices)} hint={d.draft_invoices ? "بانتظار المطابقة والترحيل" : undefined} />
      </div>

      <div className="mb-4 grid gap-4 lg:grid-cols-3">
        <Card className="p-4 lg:col-span-2">
          <h2 className="mb-3 font-semibold text-slate-900">أعمار الديون</h2>
          <div className="grid grid-cols-5 gap-2 text-center text-xs">
            {([["غير مستحق", d.overdue.not_due, "bg-slate-100"], ["1–30", d.overdue.d1_30, "bg-amber-50"], ["31–60", d.overdue.d31_60, "bg-orange-50"],
               ["61–90", d.overdue.d61_90, "bg-red-50"], ["+90", d.overdue.d90_plus, "bg-red-100"]] as const).map(([label, v, cls]) => (
              <div key={label} className={`rounded-lg p-2 ${cls}`}>
                <p className="text-slate-600">{label}</p>
                <p className="mt-1 text-sm font-bold text-slate-900">{money(v)}</p>
              </div>
            ))}
          </div>
        </Card>
        <Card className="p-4">
          <h2 className="mb-3 flex items-center gap-1.5 font-semibold text-slate-900"><TrendingUp className="size-4" /> المشتريات الشهرية</h2>
          {d.purchases_by_month.length === 0 ? (
            <p className="text-sm text-slate-500">لا توجد فواتير مرحّلة.</p>
          ) : (
            <ul className="space-y-1.5 text-xs">
              {d.purchases_by_month.map((m) => (
                <li key={m.month} className="flex items-center gap-2">
                  <span className="ltr-nums w-14 shrink-0 text-slate-500">{m.month}</span>
                  <span className="h-3 rounded bg-brand-700/70" style={{ width: `${(n(m.subtotal) / maxMonth) * 100}%` }} />
                  <span className="shrink-0">{money(m.subtotal)}</span>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>

      <Card className="mb-4">
        <div className="border-b border-slate-100 p-3">
          <h2 className="font-semibold text-slate-900">الموردون حسب الرصيد</h2>
        </div>
        {aging.length === 0 ? (
          <EmptyState title="لا توجد أرصدة للموردين" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>المورد</th>
                <th>غير مستحق</th>
                <th>1–30</th>
                <th>31–60</th>
                <th>61–90</th>
                <th>+90</th>
                <th>مقدّم/دائن</th>
                <th>الصافي</th>
              </tr>
            </thead>
            <tbody>
              {aging.map((r) => (
                <tr key={r.supplier_id}>
                  <td>
                    <Link href={`/suppliers/${r.supplier_id}`} className="font-medium text-brand-700 hover:underline">{r.supplier_name}</Link>
                    {r.credit_limit !== null && r.net_balance > n(r.credit_limit) && <Badge tone="red">فوق الحد</Badge>}
                  </td>
                  <td>{r.not_due ? money(r.not_due) : "-"}</td>
                  <td>{r.d1_30 ? money(r.d1_30) : "-"}</td>
                  <td>{r.d31_60 ? money(r.d31_60) : "-"}</td>
                  <td>{r.d61_90 ? money(r.d61_90) : "-"}</td>
                  <td className={r.d90_plus ? "font-semibold text-red-700" : ""}>{r.d90_plus ? money(r.d90_plus) : "-"}</td>
                  <td>{r.unapplied ? money(-r.unapplied) : "-"}</td>
                  <td className="font-semibold">{money(r.net_balance)}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <div className="border-b border-slate-100 p-3"><h2 className="font-semibold text-slate-900">تنبيهات الأسعار (ارتفاع 10%+ خلال 60 يوماً)</h2></div>
          {d.price_alerts.length === 0 ? <EmptyState title="لا توجد ارتفاعات لافتة" /> : (
            <Table>
              <thead><tr><th>الصنف</th><th>المورد</th><th>السعر</th><th>التغير</th></tr></thead>
              <tbody>
                {d.price_alerts.map((a, i) => (
                  <tr key={i}>
                    <td className="ltr-nums">{a.sku}</td>
                    <td>{a.supplier_name}</td>
                    <td>{money(a.unit_cost)}</td>
                    <td><Badge tone="red">+{a.change_pct}%</Badge></td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
        <Card>
          <div className="border-b border-slate-100 p-3"><h2 className="font-semibold text-slate-900">أوامر شراء متأخرة عن موعدها</h2></div>
          {d.late_orders.length === 0 ? <EmptyState title="لا توجد أوامر متأخرة" /> : (
            <Table>
              <thead><tr><th>الأمر</th><th>المورد</th><th>الموعد</th><th>التأخير</th></tr></thead>
              <tbody>
                {d.late_orders.map((o) => (
                  <tr key={o.id}>
                    <td><Link href={`/purchases/${o.id}`} className="ltr-nums text-brand-700 hover:underline">{o.po_no}</Link></td>
                    <td>{o.supplier_name}</td>
                    <td className="ltr-nums">{dateOnly(o.expected_at)}</td>
                    <td><Badge tone="amber">{o.days_late} يوماً</Badge></td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      </div>
    </div>
  );
}
