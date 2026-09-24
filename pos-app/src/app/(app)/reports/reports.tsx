"use client";

import { Download } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { ColumnChart, RankBars } from "@/components/bar-chart";
import { Button, Card, Input, Loading, PageHeader, Stat, Table, cn, useToast } from "@/components/ui";
import { downloadCsv } from "@/lib/csv";
import { PAYMENT_LABELS, REFUND_LABELS, errorMessage, isoDay, money, num } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { PaymentMethod, RefundMethod } from "@/lib/types";

interface Report {
  summary: {
    gross_sales: number;
    invoices: number;
    discounts: number;
    returns: number;
    returns_count: number;
    net_sales: number;
    vat: number;
    net_excl_vat: number;
    cost: number;
    gross_profit: number;
    margin: number;
    avg_ticket: number;
    items_sold: number;
  };
  by_day: { day: string; sales: number; returns: number; invoices: number; profit: number }[];
  by_payment: { method: PaymentMethod; amount: number; count: number }[];
  refunds_by_method: { method: RefundMethod; amount: number; count: number }[];
  by_cashier: { name: string | null; invoices: number; sales: number }[];
  top_products: { name: string; qty: number; revenue: number; profit: number }[];
  by_category: { name: string; qty: number; revenue: number; profit: number }[];
  by_size: { name: string; qty: number; revenue: number }[];
}

function presets() {
  const now = new Date();
  const today = isoDay(now);
  const d = (offset: number) => isoDay(new Date(now.getTime() - offset * 864e5));
  const [y, m] = today.split("-").map(Number);
  const monthStart = `${y}-${String(m).padStart(2, "0")}-01`;
  const lastMonthEnd = isoDay(new Date(Date.UTC(y, m - 1, 0)));
  const lastMonthStart = lastMonthEnd.slice(0, 8) + "01";
  return [
    { key: "today", label: "اليوم", from: today, to: today },
    { key: "yesterday", label: "أمس", from: d(1), to: d(1) },
    { key: "7", label: "آخر 7 أيام", from: d(6), to: today },
    { key: "month", label: "هذا الشهر", from: monthStart, to: today },
    { key: "last_month", label: "الشهر الماضي", from: lastMonthStart, to: lastMonthEnd },
    { key: "year", label: "هذه السنة", from: `${y}-01-01`, to: today },
  ];
}

export function Reports() {
  const toast = useToast();
  const [from, setFrom] = useState(() => presets()[3].from);
  const [to, setTo] = useState(() => presets()[3].to);
  const [report, setReport] = useState<Report | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase().rpc("sales_report", { p_from: from, p_to: to });
    setLoading(false);
    if (error) return toast(errorMessage(error), "error");
    setReport(data as Report);
  }, [from, to, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reload when the range changes
    load();
  }, [load]);

  const s = report?.summary;

  const exportCsv = () => {
    if (!report) return;
    downloadCsv(
      `sales-${from}_${to}.csv`,
      ["اليوم", "المبيعات", "المرتجعات", "الصافي", "الفواتير", "الربح"],
      report.by_day.map((d) => [d.day, d.sales, d.returns, Number(d.sales) - Number(d.returns), d.invoices, Number(d.profit).toFixed(2)]),
    );
  };

  const exportProducts = () => {
    if (!report) return;
    downloadCsv(
      `products-${from}_${to}.csv`,
      ["المنتج", "الكمية", "الإيراد", "الربح"],
      report.top_products.map((p) => [p.name, p.qty, p.revenue, Number(p.profit).toFixed(2)]),
    );
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="التقارير"
        subtitle="المبيعات والأرباح والضريبة"
        actions={
          <>
            <Button variant="outline" onClick={exportCsv} disabled={!report}>
              <Download className="size-4" /> تصدير يومي CSV
            </Button>
            <Button variant="outline" onClick={exportProducts} disabled={!report}>
              <Download className="size-4" /> تصدير المنتجات
            </Button>
          </>
        }
      />

      <Card className="mb-4 flex flex-wrap items-center gap-2 p-3">
        {presets().map((p) => (
          <button
            key={p.key}
            onClick={() => {
              setFrom(p.from);
              setTo(p.to);
            }}
            className={cn(
              "rounded-full px-3 py-1.5 text-sm",
              from === p.from && to === p.to ? "bg-slate-900 text-white" : "bg-slate-100 hover:bg-slate-200",
            )}
          >
            {p.label}
          </button>
        ))}
        <div className="ms-auto flex items-center gap-2">
          <Input type="date" className="w-auto" value={from} onChange={(e) => setFrom(e.target.value)} />
          <span className="text-slate-400">—</span>
          <Input type="date" className="w-auto" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
      </Card>

      {loading && !report ? (
        <Loading />
      ) : report && s ? (
        <div className={cn("space-y-4", loading && "opacity-60")}>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Stat label="إجمالي المبيعات" value={money(s.gross_sales)} hint={`${num(s.invoices)} فاتورة · متوسط ${money(s.avg_ticket)}`} tone="green" />
            <Stat label="المرتجعات" value={money(s.returns)} hint={`${num(s.returns_count)} عملية`} tone="red" />
            <Stat label="صافي المبيعات" value={money(s.net_sales)} hint={`${num(s.items_sold)} قطعة`} />
            <Stat label="الخصومات" value={money(s.discounts)} />
          </div>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Stat label="الصافي قبل الضريبة" value={money(s.net_excl_vat)} />
            <Stat label="ضريبة المخرجات المستحقة" value={money(s.vat)} tone="amber" hint="15% — للإقرار الضريبي" />
            <Stat label="تكلفة البضاعة المباعة" value={money(s.cost)} />
            <Stat label="مجمل الربح" value={money(s.gross_profit)} hint={`هامش ${s.margin}%`} tone="blue" />
          </div>

          <Card className="p-4">
            <p className="mb-4 font-semibold">صافي المبيعات اليومية</p>
            {report.by_day.length === 0 ? (
              <p className="py-8 text-center text-sm text-slate-500">لا توجد بيانات</p>
            ) : (
              <ColumnChart
                data={report.by_day.map((d) => ({
                  label: d.day.slice(5).replace("-", "/"),
                  value: Number(d.sales) - Number(d.returns),
                  hint: `ربح ${money(d.profit)}`,
                }))}
                format={money}
              />
            )}
          </Card>

          <div className="grid gap-4 lg:grid-cols-3">
            <Card className="p-4">
              <p className="mb-3 font-semibold">المقبوضات حسب طريقة الدفع</p>
              <RankBars data={report.by_payment.map((p) => ({ label: PAYMENT_LABELS[p.method], value: Number(p.amount), hint: `${p.count}` }))} format={money} />
              {report.refunds_by_method.length > 0 && (
                <>
                  <p className="mb-2 mt-5 text-sm font-semibold text-red-700">المبالغ المستردة</p>
                  {report.refunds_by_method.map((r) => (
                    <div key={r.method} className="flex justify-between text-sm">
                      <span>{REFUND_LABELS[r.method]}</span>
                      <span className="text-red-600">{money(r.amount)}</span>
                    </div>
                  ))}
                </>
              )}
            </Card>
            <Card className="p-4">
              <p className="mb-3 font-semibold">حسب التصنيف</p>
              <RankBars data={report.by_category.map((c) => ({ label: c.name, value: Number(c.revenue), hint: `${num(c.qty)} قطعة` }))} format={money} />
            </Card>
            <Card className="p-4">
              <p className="mb-3 font-semibold">المقاسات الأكثر طلباً</p>
              <RankBars data={report.by_size.slice(0, 10).map((c) => ({ label: c.name, value: Number(c.qty) }))} format={(n) => `${num(n)} قطعة`} />
            </Card>
          </div>

          <div className="grid gap-4 lg:grid-cols-3">
            <Card className="lg:col-span-2">
              <p className="p-4 pb-2 font-semibold">المنتجات الأعلى إيراداً</p>
              <Table>
                <thead>
                  <tr>
                    <th>المنتج</th>
                    <th>الكمية</th>
                    <th>الإيراد</th>
                    <th>الربح</th>
                  </tr>
                </thead>
                <tbody>
                  {report.top_products.map((p) => (
                    <tr key={p.name}>
                      <td>{p.name}</td>
                      <td>{num(p.qty)}</td>
                      <td>{money(p.revenue)}</td>
                      <td className={Number(p.profit) < 0 ? "text-red-600" : "text-emerald-700"}>{money(p.profit)}</td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            </Card>
            <Card>
              <p className="p-4 pb-2 font-semibold">أداء الكاشير</p>
              <Table>
                <thead>
                  <tr>
                    <th>الموظف</th>
                    <th>الفواتير</th>
                    <th>المبيعات</th>
                  </tr>
                </thead>
                <tbody>
                  {report.by_cashier.map((c) => (
                    <tr key={c.name ?? "-"}>
                      <td>{c.name ?? "-"}</td>
                      <td>{num(c.invoices)}</td>
                      <td>{money(c.sales)}</td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            </Card>
          </div>
        </div>
      ) : null}
    </div>
  );
}
