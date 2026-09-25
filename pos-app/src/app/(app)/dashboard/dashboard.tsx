"use client";

import { AlertTriangle, Banknote, Boxes, Receipt, RefreshCw, TrendingUp, Undo2 } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { ColumnChart, RankBars } from "@/components/bar-chart";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, Loading, PageHeader, Stat, Table, useToast } from "@/components/ui";
import { PAYMENT_LABELS, SALE_STATUS_LABELS, dateTime, errorMessage, money, num, variantLabel } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import { presets } from "@/lib/periods";
import type { ExpensesSummary, PaymentMethod, SaleStatus } from "@/lib/types";

interface Stats {
  today: { sales: number; count: number; vat: number; returns: number; profit: number };
  month: { sales: number; count: number; returns: number; profit: number };
  daily: { day: string; total: number; count: number }[];
  payments_today: { method: PaymentMethod; amount: number }[];
  top_products: { name: string; qty: number; total: number }[];
  low_stock: { id: string; name: string; size: string | null; color: string | null; sku: string; stock_qty: number; low_stock_threshold: number }[];
  low_stock_count: number;
  stock_value: { cost: number; retail: number; units: number };
  recent: { id: string; invoice_no: string; total: number; status: SaleStatus; created_at: string; cashier: string | null }[];
}

export function Dashboard() {
  const toast = useToast();
  const { profile } = useSession();
  const [stats, setStats] = useState<Stats | null>(null);
  const [monthExpenses, setMonthExpenses] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    const db = supabase();
    const month = presets()[3];
    const [{ data, error }, { data: exp, error: expErr }] = await Promise.all([
      db.rpc("dashboard_stats"),
      db.rpc("expenses_summary", { p_from: month.from, p_to: month.to }),
    ]);
    setLoading(false);
    if (error) return toast(errorMessage(error), "error");
    setStats(data as Stats);
    setMonthExpenses(expErr ? null : Number((exp as ExpensesSummary).net));
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
    const t = setInterval(load, 60_000);
    return () => clearInterval(t);
  }, [load]);

  if (!stats) return <Loading />;
  const t = stats.today;
  const m = stats.month;
  const avg = t.count > 0 ? t.sales / t.count : 0;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={`مرحباً ${profile.full_name}`}
        subtitle="ملخص أداء المتجر — يتحدث تلقائياً كل دقيقة"
        actions={
          <Button variant="outline" onClick={load} loading={loading}>
            <RefreshCw className="size-4" /> تحديث
          </Button>
        }
      />

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="مبيعات اليوم" value={money(t.sales)} hint={`${num(t.count)} فاتورة · متوسط ${money(avg)}`} icon={<Banknote className="size-5" />} tone="green" />
        <Stat label="ربح اليوم (تقديري)" value={money(t.profit)} hint="بعد التكلفة وقبل المصاريف" icon={<TrendingUp className="size-5" />} tone="blue" />
        <Stat label="مرتجعات اليوم" value={money(t.returns)} hint={`ضريبة مستحقة اليوم ${money(t.vat)}`} icon={<Undo2 className="size-5" />} tone="red" />
        <Stat label="أصناف منخفضة" value={num(stats.low_stock_count)} hint="تحتاج إعادة طلب" icon={<AlertTriangle className="size-5" />} tone="amber" />
      </div>

      <div className="mt-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="مبيعات الشهر" value={money(m.sales)} hint={`${num(m.count)} فاتورة`} icon={<Receipt className="size-5" />} />
        <Stat label="صافي الشهر" value={money(m.sales - m.returns)} hint={`مرتجعات ${money(m.returns)}`} />
        {monthExpenses === null ? (
          <Stat label="ربح الشهر" value={money(m.profit)} tone="green" />
        ) : (
          <Stat
            label="صافي ربح الشهر"
            value={money(Number(m.profit) - monthExpenses)}
            hint={`مجمل ${money(m.profit)} − مصروفات ${money(monthExpenses)}`}
            tone={Number(m.profit) - monthExpenses >= 0 ? "green" : "red"}
          />
        )}
        <Stat label="قيمة المخزون (تكلفة)" value={money(stats.stock_value.cost)} hint={`${num(stats.stock_value.units)} قطعة · بيع ${money(stats.stock_value.retail)}`} icon={<Boxes className="size-5" />} />
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Card className="p-4 lg:col-span-2">
          <p className="mb-4 font-semibold">صافي المبيعات — آخر 14 يوماً</p>
          <ColumnChart
            data={stats.daily.map((d) => ({ label: d.day.slice(5).replace("-", "/"), value: Number(d.total), hint: `${d.count} فاتورة` }))}
            format={money}
          />
        </Card>
        <Card className="p-4">
          <p className="mb-4 font-semibold">طرق الدفع اليوم</p>
          {stats.payments_today.length === 0 ? (
            <p className="py-8 text-center text-sm text-slate-500">لا توجد مبيعات اليوم</p>
          ) : (
            <RankBars data={stats.payments_today.map((p) => ({ label: PAYMENT_LABELS[p.method], value: Number(p.amount) }))} format={money} />
          )}
        </Card>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Card className="p-4">
          <p className="mb-4 font-semibold">الأكثر مبيعاً (30 يوماً)</p>
          {stats.top_products.length === 0 ? (
            <p className="py-8 text-center text-sm text-slate-500">لا توجد بيانات</p>
          ) : (
            <RankBars data={stats.top_products.map((p) => ({ label: p.name, value: Number(p.qty), hint: money(p.total) }))} format={(n) => `${num(n)} قطعة`} />
          )}
        </Card>
        <Card className="lg:col-span-2">
          <div className="flex items-center justify-between p-4 pb-2">
            <p className="font-semibold">تنبيهات المخزون</p>
            <Link href="/inventory" className="text-sm text-brand-700 hover:underline">
              عرض المخزون
            </Link>
          </div>
          {stats.low_stock.length === 0 ? (
            <p className="py-8 text-center text-sm text-slate-500">المخزون بحالة جيدة</p>
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>الصنف</th>
                  <th>SKU</th>
                  <th>المتوفر</th>
                  <th>حد التنبيه</th>
                </tr>
              </thead>
              <tbody>
                {stats.low_stock.map((v) => (
                  <tr key={v.id}>
                    <td>
                      {v.name} <span className="text-slate-500">{variantLabel(v.size, v.color)}</span>
                    </td>
                    <td className="ltr-nums text-xs">{v.sku}</td>
                    <td>
                      <Badge tone={v.stock_qty <= 0 ? "red" : "amber"}>{v.stock_qty}</Badge>
                    </td>
                    <td>{v.low_stock_threshold}</td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      </div>

      <Card className="mt-4">
        <div className="flex items-center justify-between p-4 pb-2">
          <p className="font-semibold">آخر الفواتير</p>
          <Link href="/sales" className="text-sm text-brand-700 hover:underline">
            كل الفواتير
          </Link>
        </div>
        <Table>
          <thead>
            <tr>
              <th>الفاتورة</th>
              <th>الوقت</th>
              <th>الكاشير</th>
              <th>الإجمالي</th>
              <th>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {stats.recent.map((s) => (
              <tr key={s.id}>
                <td>
                  <Link href={`/sales/${s.id}`} className="text-brand-700 hover:underline">
                    {s.invoice_no}
                  </Link>
                </td>
                <td className="ltr-nums">{dateTime(s.created_at)}</td>
                <td>{s.cashier ?? "-"}</td>
                <td className="font-semibold">{money(s.total)}</td>
                <td>
                  <Badge tone={s.status === "completed" ? "green" : "amber"}>{SALE_STATUS_LABELS[s.status]}</Badge>
                </td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Card>
    </div>
  );
}
