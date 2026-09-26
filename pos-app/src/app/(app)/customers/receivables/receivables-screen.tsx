"use client";

import { Download, MessageCircle } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Button, Card, EmptyState, Loading, PageHeader, Stat, Table, cn, useToast } from "@/components/ui";
import { COLLECTION_METHOD_LABELS, openWhatsApp, waPhone } from "@/lib/customers";
import { downloadCsv } from "@/lib/csv";
import { dateOnly, dateTime, errorMessage, isoDay, money } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { CustomerPayment } from "@/lib/types";

interface Receivables {
  total_receivable: number;
  total_credit_balances: number;
  d0_30: number;
  d31_60: number;
  d61_90: number;
  d90_plus: number;
  customers: Array<{
    id: string;
    name: string;
    phone: string | null;
    balance: number;
    credit_limit: number | null;
    d0_30: number;
    d31_60: number;
    d61_90: number;
    d90_plus: number;
    last_payment_at: string | null;
  }>;
}

export function ReceivablesScreen() {
  const toast = useToast();
  const { settings } = useSession();
  const [r, setR] = useState<Receivables | null>(null);
  const [payments, setPayments] = useState<Array<CustomerPayment & { customer: { name: string } | null }>>([]);

  const load = useCallback(async () => {
    const db = supabase();
    const [rep, pay] = await Promise.all([
      db.rpc("receivables_report"),
      db.from("customer_payments").select("*, customer:customers(name)").order("created_at", { ascending: false }).limit(30),
    ]);
    if (rep.error) toast(errorMessage(rep.error), "error");
    setR(rep.data as Receivables);
    setPayments((pay.data ?? []) as typeof payments);
  }, [toast]);

  useEffect(() => {
    (async () => {
      await load();
    })();
  }, [load]);

  if (!r) return <Loading />;
  const owing = r.customers.filter((c) => Number(c.balance) > 0);
  const credits = r.customers.filter((c) => Number(c.balance) < 0);

  const remind = (c: Receivables["customers"][number]) => {
    const phone = waPhone(c.phone);
    if (!phone) return toast("لا يوجد رقم جوال صحيح", "error");
    openWhatsApp({
      phone,
      kind: "reminder",
      customerId: c.id,
      text: `مرحباً ${c.name}،\nنود تذكيركم بأن الرصيد المستحق لدى ${settings.store_name} هو ${money(c.balance)}.\nشكراً لتعاملكم معنا.`,
    }).catch((e) => toast(errorMessage(e), "error"));
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="الذمم والتحصيل"
        subtitle="أعمار الذمم بطريقة FIFO: التحصيل يسدد أقدم الفواتير الآجلة أولاً"
        actions={
          <Button
            variant="outline"
            onClick={() =>
              downloadCsv(
                `receivables-${isoDay()}.csv`,
                ["العميل", "الجوال", "الرصيد", "حد الائتمان", "0-30", "31-60", "61-90", "+90", "آخر تحصيل"],
                r.customers.map((c) => [c.name, c.phone, c.balance, c.credit_limit, c.d0_30, c.d31_60, c.d61_90, c.d90_plus, dateOnly(c.last_payment_at)]),
              )
            }
          >
            <Download className="size-4" /> CSV
          </Button>
        }
      />
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-6">
        <Stat label="إجمالي المستحق" value={money(r.total_receivable)} tone="red" />
        <Stat label="0 – 30 يوماً" value={money(r.d0_30)} />
        <Stat label="31 – 60 يوماً" value={money(r.d31_60)} tone="amber" />
        <Stat label="61 – 90 يوماً" value={money(r.d61_90)} tone="amber" />
        <Stat label="أكثر من 90 يوماً" value={money(r.d90_plus)} tone="red" />
        <Stat label="أرصدة دائنة للعملاء" value={money(r.total_credit_balances)} tone="green" hint="عربون أو مرتجع إلى الحساب" />
      </div>

      <Card className="mt-4">
        <p className="border-b border-slate-100 p-3 font-semibold">العملاء المدينون ({owing.length})</p>
        {owing.length === 0 ? (
          <EmptyState title="لا توجد ذمم مستحقة" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>العميل</th>
                <th>المستحق</th>
                <th>الحد</th>
                <th>0-30</th>
                <th>31-60</th>
                <th>61-90</th>
                <th>+90</th>
                <th>آخر تحصيل</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {owing.map((c) => (
                <tr key={c.id}>
                  <td>
                    <Link href={`/customers/${c.id}`} className="font-medium text-brand-700 hover:underline">
                      {c.name}
                    </Link>
                    <p className="ltr-nums text-xs text-slate-500">{c.phone}</p>
                  </td>
                  <td className="font-bold tabular-nums text-red-600">{money(c.balance)}</td>
                  <td className={cn("tabular-nums", c.credit_limit != null && Number(c.balance) > Number(c.credit_limit) && "text-red-600")}>
                    {c.credit_limit != null ? money(c.credit_limit) : "—"}
                  </td>
                  <td className="tabular-nums">{Number(c.d0_30) ? money(c.d0_30) : "—"}</td>
                  <td className="tabular-nums">{Number(c.d31_60) ? money(c.d31_60) : "—"}</td>
                  <td className="tabular-nums">{Number(c.d61_90) ? money(c.d61_90) : "—"}</td>
                  <td className="tabular-nums text-red-600">{Number(c.d90_plus) ? money(c.d90_plus) : "—"}</td>
                  <td className="ltr-nums text-slate-600">{dateOnly(c.last_payment_at)}</td>
                  <td>
                    {c.phone && (
                      <button className="text-emerald-700" onClick={() => remind(c)} title="تذكير واتساب" aria-label="تذكير واتساب">
                        <MessageCircle className="size-4" />
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      {credits.length > 0 && (
        <Card className="mt-4">
          <p className="border-b border-slate-100 p-3 font-semibold">أرصدة دائنة للعملاء</p>
          <ul className="divide-y divide-slate-100">
            {credits.map((c) => (
              <li key={c.id} className="flex items-center justify-between p-3 text-sm">
                <Link href={`/customers/${c.id}`} className="text-brand-700 hover:underline">
                  {c.name}
                </Link>
                <span className="font-semibold text-emerald-700">{money(-c.balance)}</span>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <Card className="mt-4">
        <p className="border-b border-slate-100 p-3 font-semibold">آخر السندات</p>
        {payments.length === 0 ? (
          <EmptyState title="لا توجد سندات" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>السند</th>
                <th>العميل</th>
                <th>التاريخ</th>
                <th>النوع</th>
                <th>الطريقة</th>
                <th>المبلغ</th>
              </tr>
            </thead>
            <tbody>
              {payments.map((p) => (
                <tr key={p.id} className={cn(p.voided_at && "line-through opacity-60")}>
                  <td dir="ltr">{p.receipt_no}</td>
                  <td>
                    <Link href={`/customers/${p.customer_id}`} className="hover:underline">
                      {p.customer?.name}
                    </Link>
                  </td>
                  <td className="ltr-nums text-slate-600">{dateTime(p.created_at)}</td>
                  <td>{p.kind === "receipt" ? (p.reservation_id ? "عربون" : "تحصيل") : "رد رصيد"}</td>
                  <td>{COLLECTION_METHOD_LABELS[p.method]}</td>
                  <td className="font-semibold tabular-nums">{money(p.amount)}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}
