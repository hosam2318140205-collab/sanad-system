"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { Card, EmptyState, Field, Input, Loading, PageHeader, Stat, Table, cn, useToast } from "@/components/ui";
import { dateOnly, errorMessage, money, num } from "@/lib/format";
import { presets } from "@/lib/periods";
import { supabase } from "@/lib/supabase/client";

interface Analytics {
  customers_total: number;
  customers_new: number;
  customers_active: number;
  customers_returning: number;
  repeat_rate: number;
  sales_registered: number;
  sales_walkin: number;
  invoices_registered: number;
  invoices_walkin: number;
  avg_basket_registered: number;
  avg_basket_walkin: number;
  avg_spend_per_customer: number;
  top_customers: Array<{ id: string; name: string; phone: string | null; invoices: number; net: number; last_at: string; loyalty_points: number; account_balance: number }>;
  segments: Record<string, { count: number; value: number }>;
  at_risk_customers: Array<{ id: string; name: string; phone: string | null; days_since: number; invoices: number; value: number }>;
  loyalty: { enabled: boolean; points_outstanding: number; liability: number; earned: number; redeemed: number; redeemed_value: number };
  credit: { receivable: number; credit_balances: number; credit_sales: number; collections: number };
  promotions: Array<{ id: string; name: string; code: string | null; invoices: number; units: number; discount: number; revenue: number }>;
  reservations: { active: number; expired: number; fulfilled: number; cancelled: number };
  whatsapp_sent: number;
}

// قواعد الشرائح معروضة كما تُحسب في customer_analytics()
const SEGMENTS: Array<[string, string, string, string]> = [
  ["champions", "مميزون", "آخر شراء ≤ 30 يوماً و4 فواتير فأكثر خلال سنة", "bg-emerald-50 text-emerald-800"],
  ["loyal", "أوفياء", "آخر شراء ≤ 60 يوماً وفاتورتان فأكثر", "bg-sky-50 text-sky-800"],
  ["new", "جدد", "أول شراء خلال آخر 30 يوماً", "bg-violet-50 text-violet-800"],
  ["occasional", "عرضيون", "لا تنطبق عليهم الشرائح الأخرى", "bg-slate-100 text-slate-700"],
  ["at_risk", "معرّضون للفقد", "كانوا يشترون بانتظام وآخر شراء قبل 61–120 يوماً", "bg-amber-50 text-amber-800"],
  ["lost", "مفقودون", "آخر شراء قبل أكثر من 120 يوماً", "bg-red-50 text-red-800"],
];

export function CustomerAnalyticsScreen() {
  const toast = useToast();
  const ranges = presets();
  const [from, setFrom] = useState(ranges[3].from);
  const [to, setTo] = useState(ranges[3].to);
  const [a, setA] = useState<Analytics | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase().rpc("customer_analytics", { p_from: from, p_to: to });
    if (error) return toast(errorMessage(error), "error");
    setA(data as Analytics);
  }, [from, to, toast]);

  useEffect(() => {
    (async () => {
      await load();
    })();
  }, [load]);

  const registeredShare = a && Number(a.sales_registered) + Number(a.sales_walkin) > 0
    ? (100 * Number(a.sales_registered)) / (Number(a.sales_registered) + Number(a.sales_walkin))
    : 0;

  return (
    <div className="p-4 md:p-6">
      <PageHeader title="تحليلات العملاء" subtitle="من المبيعات الفعلية — كل مؤشر بقاعدة حساب واضحة" />
      <Card className="mb-4 flex flex-wrap items-end gap-2 p-3">
        {ranges.map((r) => (
          <button
            key={r.key}
            onClick={() => {
              setFrom(r.from);
              setTo(r.to);
            }}
            className={cn("rounded-full px-3 py-1.5 text-sm", from === r.from && to === r.to ? "bg-slate-900 text-white" : "bg-slate-100")}
          >
            {r.label}
          </button>
        ))}
        <Field label="من">
          <Input type="date" className="w-40" value={from} onChange={(e) => setFrom(e.target.value)} />
        </Field>
        <Field label="إلى">
          <Input type="date" className="w-40" value={to} onChange={(e) => setTo(e.target.value)} />
        </Field>
      </Card>

      {!a ? (
        <Loading />
      ) : (
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Stat label="عملاء اشتروا في الفترة" value={num(a.customers_active)} hint={`من ${num(a.customers_total)} عميل مسجل`} />
            <Stat label="عملاء جدد" value={num(a.customers_new)} tone="blue" hint={`عائدون: ${num(a.customers_returning)}`} />
            <Stat label="معدل التكرار" value={`${a.repeat_rate}%`} tone="green" hint="اشتروا مرتين فأكثر في الفترة" />
            <Stat label="متوسط إنفاق العميل" value={money(a.avg_spend_per_customer)} hint="صافي بعد المرتجعات" />
          </div>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Stat label="مبيعات العملاء المسجلين" value={money(a.sales_registered)} hint={`${registeredShare.toFixed(0)}% من المبيعات · ${num(a.invoices_registered)} فاتورة`} />
            <Stat label="متوسط الفاتورة (مسجل / نقدي)" value={money(a.avg_basket_registered)} hint={`النقدي بدون عميل: ${money(a.avg_basket_walkin)}`} />
            <Stat label="الذمم المستحقة" value={money(a.credit.receivable)} tone="red" hint={`آجل الفترة ${money(a.credit.credit_sales)} · تحصيل ${money(a.credit.collections)}`} />
            <Stat
              label="التزام النقاط"
              value={money(a.loyalty.liability)}
              tone="amber"
              hint={a.loyalty.enabled ? `${num(a.loyalty.points_outstanding)} نقطة قائمة · مستبدل ${money(a.loyalty.redeemed_value)}` : "البرنامج غير مفعّل"}
            />
          </div>

          <Card className="p-4">
            <h2 className="mb-3 font-semibold">شرائح العملاء</h2>
            <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {SEGMENTS.map(([key, label, rule, cls]) => (
                <div key={key} className={cn("rounded-xl p-3", cls)} data-testid={`segment-${key}`}>
                  <div className="flex items-baseline justify-between">
                    <p className="font-semibold">{label}</p>
                    <p className="text-xl font-bold tabular-nums">{num(a.segments[key]?.count ?? 0)}</p>
                  </div>
                  <p className="text-xs opacity-80">{rule}</p>
                  <p className="mt-1 text-xs">مشتريات سنة: {money(a.segments[key]?.value ?? 0)}</p>
                </div>
              ))}
            </div>
          </Card>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <p className="border-b border-slate-100 p-3 font-semibold">أفضل العملاء في الفترة</p>
              {a.top_customers.length === 0 ? (
                <EmptyState title="لا توجد مبيعات لعملاء مسجلين" />
              ) : (
                <Table>
                  <thead>
                    <tr>
                      <th>العميل</th>
                      <th>الفواتير</th>
                      <th>الصافي</th>
                      <th>آخر زيارة</th>
                    </tr>
                  </thead>
                  <tbody>
                    {a.top_customers.map((c) => (
                      <tr key={c.id}>
                        <td>
                          <Link href={`/customers/${c.id}`} className="text-brand-700 hover:underline">
                            {c.name}
                          </Link>
                        </td>
                        <td className="tabular-nums">{c.invoices}</td>
                        <td className="font-semibold tabular-nums">{money(c.net)}</td>
                        <td className="ltr-nums text-slate-600">{dateOnly(c.last_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </Table>
              )}
            </Card>
            <Card>
              <p className="border-b border-slate-100 p-3 font-semibold">معرّضون للفقد — تواصل معهم</p>
              {a.at_risk_customers.length === 0 ? (
                <EmptyState title="لا يوجد" />
              ) : (
                <Table>
                  <thead>
                    <tr>
                      <th>العميل</th>
                      <th>منذ (يوم)</th>
                      <th>فواتير سنة</th>
                      <th>قيمة سنة</th>
                    </tr>
                  </thead>
                  <tbody>
                    {a.at_risk_customers.map((c) => (
                      <tr key={c.id}>
                        <td>
                          <Link href={`/customers/${c.id}`} className="text-brand-700 hover:underline">
                            {c.name}
                          </Link>
                        </td>
                        <td className="tabular-nums">{c.days_since}</td>
                        <td className="tabular-nums">{c.invoices}</td>
                        <td className="tabular-nums">{money(c.value)}</td>
                      </tr>
                    ))}
                  </tbody>
                </Table>
              )}
            </Card>
          </div>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <p className="border-b border-slate-100 p-3 font-semibold">أداء العروض في الفترة</p>
              {a.promotions.length === 0 ? (
                <EmptyState title="لم تُستخدم عروض" />
              ) : (
                <Table>
                  <thead>
                    <tr>
                      <th>العرض</th>
                      <th>فواتير</th>
                      <th>قطع</th>
                      <th>الخصم</th>
                      <th>المبيعات</th>
                    </tr>
                  </thead>
                  <tbody>
                    {a.promotions.map((p) => (
                      <tr key={p.id}>
                        <td>
                          {p.name} {p.code && <span className="text-xs text-slate-500" dir="ltr">({p.code})</span>}
                        </td>
                        <td className="tabular-nums">{p.invoices}</td>
                        <td className="tabular-nums">{p.units}</td>
                        <td className="tabular-nums text-red-600">{money(p.discount)}</td>
                        <td className="tabular-nums">{money(p.revenue)}</td>
                      </tr>
                    ))}
                  </tbody>
                </Table>
              )}
            </Card>
            <Card className="p-4 text-sm">
              <h2 className="mb-2 font-semibold">الحجوزات والتواصل</h2>
              <ul className="space-y-1">
                <li>حجوزات نشطة: <b>{a.reservations.active}</b> · منتهية لم تُستلم: <b>{a.reservations.expired}</b></li>
                <li>
                  في الفترة: استلام <b>{a.reservations.fulfilled}</b> · إلغاء <b>{a.reservations.cancelled}</b>
                </li>
                <li>
                  رسائل واتساب في الفترة: <b>{a.whatsapp_sent}</b>
                </li>
                <li>
                  نقاط مكتسبة: <b>{num(a.loyalty.earned)}</b> · مستبدلة: <b>{num(a.loyalty.redeemed)}</b>
                </li>
              </ul>
            </Card>
          </div>
        </div>
      )}
    </div>
  );
}
