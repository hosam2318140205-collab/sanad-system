"use client";

import {
  ArrowRight,
  BookmarkPlus,
  Gift,
  HandCoins,
  MessageCircle,
  Pencil,
  Printer,
  ShoppingCart,
  Undo2,
} from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { PrintPortal } from "@/components/print-portal";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Stat, Table, Textarea, cn, useToast } from "@/components/ui";
import {
  AR_ENTRY_LABELS,
  COLLECTION_METHOD_LABELS,
  LOYALTY_ENTRY_LABELS,
  newClientRef,
  openWhatsApp,
  reservationState,
  waPhone,
} from "@/lib/customers";
import { SALE_STATUS_LABELS, dateOnly, dateTime, errorMessage, isoDay, money, num } from "@/lib/format";
import { printNow } from "@/lib/sales";
import { supabase } from "@/lib/supabase/client";
import type { CollectionMethod, Customer, CustomerPayment, CustomerStatement, LoyaltyEntryType, SaleStatus } from "@/lib/types";
import { CustomerFormModal } from "../customer-form";

interface Profile {
  customer: Customer;
  account: { account_balance: number; credit_limit: number | null; loyalty_points: number };
  stats: {
    invoices: number;
    gross_spent: number;
    returned: number;
    net_spent: number;
    avg_basket: number;
    first_purchase: string | null;
    last_purchase: string | null;
    days_since_last: number | null;
    units: number;
    promo_savings: number;
    points_redeemed: number;
  };
  favorite_sizes: Array<{ label: string; units: number }>;
  favorite_colors: Array<{ label: string; units: number }>;
  favorite_categories: Array<{ label: string; units: number }>;
  purchases: Array<{
    id: string;
    invoice_no: string;
    created_at: string;
    total: number;
    returned_amount: number;
    status: SaleStatus;
    public_token: string;
    is_mine: boolean;
    units: number;
    methods: string | null;
    summary: string | null;
  }>;
  reservations: Array<{
    id: string;
    reservation_no: string;
    status: "active" | "fulfilled" | "cancelled";
    expires_at: string;
    created_at: string;
    notes: string | null;
    expired: boolean;
    items: Array<{ variant_id: string; qty: number; sku: string; product_name: string; variant_label: string | null }> | null;
  }>;
  loyalty: Array<{ id: number; entry_type: LoyaltyEntryType; ref_no: string | null; points: number; balance_after: number; note: string | null; created_at: string }>;
  messages: number;
}

type Tab = "purchases" | "statement" | "loyalty" | "reservations";

export function CustomerProfile({ id }: { id: string }) {
  const toast = useToast();
  const router = useRouter();
  const { isManager, settings } = useSession();
  const [p, setP] = useState<Profile | null>(null);
  const [tab, setTab] = useState<Tab>("purchases");
  const [editing, setEditing] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase().rpc("customer_profile", { p_customer_id: id });
    if (error) {
      toast(errorMessage(error), "error");
      return;
    }
    setP(data as Profile);
  }, [id, toast]);

  useEffect(() => {
    (async () => {
      await load();
    })();
  }, [load]);

  if (!p) return <Loading />;
  const c = p.customer;
  const balance = Number(p.account.account_balance);
  const phone = waPhone(c.phone);
  const activeReservations = p.reservations.filter((r) => r.status === "active" && !r.expired).length;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={c.name}
        subtitle={[c.phone, c.city, c.vat_number && `ض: ${c.vat_number}`].filter(Boolean).join(" · ") || undefined}
        actions={
          <>
            <Link href="/customers">
              <Button variant="ghost">
                <ArrowRight className="size-4" /> العملاء
              </Button>
            </Link>
            <Button variant="outline" onClick={() => setEditing(true)}>
              <Pencil className="size-4" /> تعديل
            </Button>
            <Link href={`/reservations?customer=${c.id}`}>
              <Button variant="outline">
                <BookmarkPlus className="size-4" /> حجز
              </Button>
            </Link>
            <Link href={`/pos?customer=${c.id}`}>
              <Button>
                <ShoppingCart className="size-4" /> بيع لهذا العميل
              </Button>
            </Link>
          </>
        }
      />

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="صافي المشتريات" value={money(p.stats.net_spent)} hint={`${num(p.stats.invoices)} فاتورة · ${num(p.stats.units)} قطعة`} />
        <Stat
          label="متوسط الفاتورة"
          value={money(p.stats.avg_basket)}
          hint={p.stats.last_purchase ? `آخر زيارة منذ ${p.stats.days_since_last} يوم` : "لم يشترِ بعد"}
        />
        <Stat
          label="رصيد الحساب"
          value={balance === 0 ? "—" : money(Math.abs(balance))}
          tone={balance > 0 ? "red" : balance < 0 ? "green" : "slate"}
          hint={
            (balance > 0 ? "مستحق على العميل" : balance < 0 ? "رصيد دائن للعميل" : "لا توجد ذمة") +
            (p.account.credit_limit != null ? ` · الحد ${money(p.account.credit_limit)}` : "")
          }
        />
        <Stat
          label="نقاط الولاء"
          value={num(p.account.loyalty_points)}
          tone="amber"
          icon={<Gift className="size-5" />}
          hint={`قيمتها ${money(Number(p.account.loyalty_points) * Number(settings.loyalty_point_value))}`}
        />
      </div>

      {(p.favorite_sizes.length > 0 || p.favorite_colors.length > 0 || p.favorite_categories.length > 0) && (
        <Card className="mt-4 flex flex-wrap gap-x-6 gap-y-2 p-4 text-sm">
          <Favorites title="المقاسات المفضلة" list={p.favorite_sizes} />
          <Favorites title="الألوان المفضلة" list={p.favorite_colors} />
          <Favorites title="التصنيفات" list={p.favorite_categories} />
          {Number(p.stats.promo_savings) > 0 && <p className="text-emerald-700">وفّر من العروض {money(p.stats.promo_savings)}</p>}
        </Card>
      )}
      {c.notes && <p className="mt-3 rounded-lg bg-amber-50 p-3 text-sm text-amber-900">ملاحظات: {c.notes}</p>}

      <div className="mt-4 flex gap-1 overflow-x-auto rounded-xl bg-slate-100 p-1 scrollbar-thin" role="tablist">
        {(
          [
            ["purchases", `المشتريات (${p.stats.invoices})`],
            ["statement", "كشف الحساب والتحصيل"],
            ["loyalty", "النقاط"],
            ["reservations", `الحجوزات${activeReservations ? ` (${activeReservations})` : ""}`],
          ] as const
        ).map(([k, label]) => (
          <button
            key={k}
            role="tab"
            aria-selected={tab === k}
            onClick={() => setTab(k)}
            className={cn("shrink-0 whitespace-nowrap rounded-lg px-4 py-2 text-sm font-medium", tab === k ? "bg-white shadow-sm" : "text-slate-600")}
          >
            {label}
          </button>
        ))}
      </div>

      <div className="mt-3">
        {tab === "purchases" && <Purchases p={p} canOpenAll={isManager} />}
        {tab === "statement" && <Statement customer={c} phone={phone} creditLimit={p.account.credit_limit} onChanged={load} />}
        {tab === "loyalty" && <Loyalty p={p} onChanged={load} />}
        {tab === "reservations" && <Reservations p={p} phone={phone} onChanged={load} onFulfil={(rid) => router.push(`/pos?reservation=${rid}`)} />}
      </div>

      <CustomerFormModal
        open={editing}
        customer={c}
        onClose={() => setEditing(false)}
        onSaved={() => {
          setEditing(false);
          load();
        }}
        onDeleted={() => router.push("/customers")}
      />
    </div>
  );
}

function Favorites({ title, list }: { title: string; list: Array<{ label: string; units: number }> }) {
  if (list.length === 0) return null;
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <span className="text-slate-500">{title}:</span>
      {list.map((f) => (
        <Badge key={f.label} tone="blue">
          {f.label} ({f.units})
        </Badge>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- المشتريات
function Purchases({ p, canOpenAll }: { p: Profile; canOpenAll: boolean }) {
  if (p.purchases.length === 0) return <Card><EmptyState title="لا توجد مشتريات" /></Card>;
  return (
    <Card>
      <ul className="divide-y divide-slate-100 md:hidden">
        {p.purchases.map((s) => (
          <li key={s.id} className="p-3">
            <div className="flex items-center justify-between gap-2">
              <p className="font-medium" dir="ltr">{s.invoice_no}</p>
              <p className="font-semibold">{money(s.total)}</p>
            </div>
            <p className="text-xs text-slate-500">{dateTime(s.created_at)} · {s.units} قطعة</p>
            {s.summary && <p className="mt-1 line-clamp-2 text-xs text-slate-600">{s.summary}</p>}
            {s.status !== "completed" && <Badge tone="amber">{SALE_STATUS_LABELS[s.status]}</Badge>}
          </li>
        ))}
      </ul>
      <Table className="hidden md:block">
        <thead>
          <tr>
            <th>الفاتورة</th>
            <th>التاريخ</th>
            <th>الأصناف</th>
            <th>القطع</th>
            <th>الإجمالي</th>
            <th>مرتجع</th>
            <th>الحالة</th>
          </tr>
        </thead>
        <tbody>
          {p.purchases.map((s) => (
            <tr key={s.id}>
              <td>
                {canOpenAll || s.is_mine ? (
                  <Link href={`/sales/${s.id}`} className="text-brand-700 hover:underline" dir="ltr">
                    {s.invoice_no}
                  </Link>
                ) : (
                  <a href={`/r/${s.public_token}`} target="_blank" rel="noreferrer" className="text-brand-700 hover:underline" dir="ltr">
                    {s.invoice_no}
                  </a>
                )}
              </td>
              <td className="ltr-nums text-slate-600">{dateTime(s.created_at)}</td>
              <td className="max-w-72 truncate text-slate-600" title={s.summary ?? ""}>{s.summary}</td>
              <td className="tabular-nums">{s.units}</td>
              <td className="font-semibold tabular-nums">{money(s.total)}</td>
              <td className="tabular-nums text-red-600">{Number(s.returned_amount) > 0 ? money(s.returned_amount) : "—"}</td>
              <td>
                <Badge tone={s.status === "completed" ? "green" : "amber"}>{SALE_STATUS_LABELS[s.status]}</Badge>
              </td>
            </tr>
          ))}
        </tbody>
      </Table>
    </Card>
  );
}

// ---------------------------------------------------------------- كشف الحساب والتحصيل
function Statement({
  customer,
  phone,
  creditLimit,
  onChanged,
}: {
  customer: Customer;
  phone: string | null;
  creditLimit: number | null;
  onChanged: () => void;
}) {
  const toast = useToast();
  const { isManager, settings, profile } = useSession();
  const [from, setFrom] = useState("");
  const [to, setTo] = useState(isoDay());
  const [st, setSt] = useState<CustomerStatement | null>(null);
  const [payments, setPayments] = useState<CustomerPayment[]>([]);
  const [collect, setCollect] = useState<"receipt" | "refund" | null>(null);
  const [voiding, setVoiding] = useState<CustomerPayment | null>(null);
  const [voidReason, setVoidReason] = useState("");
  const [limitOpen, setLimitOpen] = useState(false);
  const [limit, setLimit] = useState("");
  const [printing, setPrinting] = useState(false);

  const load = useCallback(async () => {
    const db = supabase();
    const [s, pay] = await Promise.all([
      db.rpc("customer_statement", { p_customer_id: customer.id, p_from: from || null, p_to: to || null }),
      db.from("customer_payments").select("*").eq("customer_id", customer.id).order("created_at", { ascending: false }).limit(50),
    ]);
    if (s.error) toast(errorMessage(s.error), "error");
    setSt(s.data as CustomerStatement);
    setPayments((pay.data ?? []) as CustomerPayment[]);
  }, [customer.id, from, to, toast]);

  useEffect(() => {
    (async () => {
      await load();
    })();
  }, [load]);

  const refresh = () => {
    load();
    onChanged();
  };

  const closing = Number(st?.closing_balance ?? 0);

  const sendStatement = () => {
    if (!phone || !st) return;
    const text = [
      `مرحباً ${customer.name}،`,
      `كشف حسابك لدى ${settings.store_name}${st.from ? ` من ${st.from}` : ""} حتى ${st.to}:`,
      `الرصيد الافتتاحي: ${money(st.opening_balance)}`,
      `فواتير آجلة: ${money(st.total_debit)} — مدفوعات ومرتجعات: ${money(st.total_credit)}`,
      closing > 0 ? `المستحق عليكم: ${money(closing)}` : closing < 0 ? `رصيدكم الدائن: ${money(-closing)}` : "لا يوجد رصيد مستحق",
      "",
      "شكراً لتعاملكم معنا.",
    ].join("\n");
    openWhatsApp({ phone, text, kind: "statement", customerId: customer.id }).catch((e) => toast(errorMessage(e), "error"));
  };

  const doVoid = async () => {
    if (!voiding || !voidReason.trim()) return;
    const { error } = await supabase().rpc("void_customer_payment", { p_payment_id: voiding.id, p_reason: voidReason.trim() });
    if (error) return toast(errorMessage(error), "error");
    toast("تم إلغاء السند وعكس قيده");
    setVoiding(null);
    setVoidReason("");
    refresh();
  };

  const saveLimit = async () => {
    const value = limit.trim() === "" ? null : Number(limit);
    if (value !== null && !(value >= 0)) return toast("حد غير صحيح", "error");
    const { error } = await supabase().rpc("set_credit_limit", { p_customer_id: customer.id, p_limit: value });
    if (error) return toast(errorMessage(error), "error");
    toast(value === null ? "تم إيقاف البيع الآجل لهذا العميل" : "تم حفظ حد الائتمان");
    setLimitOpen(false);
    refresh();
  };

  return (
    <div className="space-y-3">
      <Card className="p-3">
        <div className="flex flex-wrap items-end gap-2">
          <Field label="من">
            <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className="w-40" />
          </Field>
          <Field label="إلى">
            <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} className="w-40" />
          </Field>
          <div className="ms-auto flex flex-wrap gap-2">
            <Button onClick={() => setCollect("receipt")}>
              <HandCoins className="size-4" /> تحصيل دفعة
            </Button>
            {isManager && closing < 0 && (
              <Button variant="outline" onClick={() => setCollect("refund")}>
                <Undo2 className="size-4" /> رد رصيد
              </Button>
            )}
            {isManager && (
              <Button
                variant="outline"
                onClick={() => {
                  setLimit(creditLimit != null ? String(creditLimit) : "");
                  setLimitOpen(true);
                }}
              >
                حد الائتمان: {creditLimit != null ? money(creditLimit) : "غير مسموح"}
              </Button>
            )}
            {phone && (
              <Button variant="outline" className="border-emerald-600 text-emerald-700" onClick={sendStatement}>
                <MessageCircle className="size-4" /> إرسال الكشف
              </Button>
            )}
            <Button
              variant="outline"
              onClick={() => {
                setPrinting(true);
                printNow();
                setTimeout(() => setPrinting(false), 1500);
              }}
            >
              <Printer className="size-4" /> طباعة
            </Button>
          </div>
        </div>
      </Card>

      {st && (
        <Card>
          <div className="grid grid-cols-2 gap-3 border-b border-slate-100 p-4 text-sm sm:grid-cols-4">
            <div>
              <p className="text-slate-500">رصيد أول المدة</p>
              <p className="font-semibold">{money(st.opening_balance)}</p>
            </div>
            <div>
              <p className="text-slate-500">مدين (آجل)</p>
              <p className="font-semibold">{money(st.total_debit)}</p>
            </div>
            <div>
              <p className="text-slate-500">دائن (تحصيل/مرتجع)</p>
              <p className="font-semibold">{money(st.total_credit)}</p>
            </div>
            <div>
              <p className="text-slate-500">الرصيد</p>
              <p className={cn("text-lg font-bold", closing > 0 ? "text-red-600" : closing < 0 ? "text-emerald-700" : "")} data-testid="statement-closing">
                {money(closing)}
              </p>
            </div>
          </div>
          {st.entries.length === 0 ? (
            <EmptyState title="لا توجد حركات في هذه الفترة" />
          ) : (
            <StatementTable st={st} />
          )}
        </Card>
      )}

      <Card>
        <p className="border-b border-slate-100 p-3 font-semibold">سندات التحصيل</p>
        {payments.length === 0 ? (
          <EmptyState title="لا توجد سندات" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>السند</th>
                <th>التاريخ</th>
                <th>النوع</th>
                <th>الطريقة</th>
                <th>المبلغ</th>
                <th>ملاحظات</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {payments.map((x) => (
                <tr key={x.id} className={cn(x.voided_at && "opacity-60")}>
                  <td className="font-medium" dir="ltr">{x.receipt_no}</td>
                  <td className="ltr-nums text-slate-600">{dateTime(x.created_at)}</td>
                  <td>{x.kind === "receipt" ? (x.reservation_id ? "عربون حجز" : "تحصيل") : "رد رصيد"}</td>
                  <td>{COLLECTION_METHOD_LABELS[x.method]}</td>
                  <td className="font-semibold tabular-nums">{money(x.amount)}</td>
                  <td className="max-w-48 truncate text-slate-600">{x.voided_at ? `ملغي: ${x.void_reason}` : (x.notes ?? x.reference ?? "")}</td>
                  <td>
                    {isManager && !x.voided_at && (
                      <button className="text-xs text-red-600 hover:underline" onClick={() => setVoiding(x)}>
                        إلغاء
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      {collect && (
        <CollectionModal
          customer={customer}
          kind={collect}
          maxRefund={Math.max(-closing, 0)}
          isManager={isManager}
          onClose={() => setCollect(null)}
          onDone={() => {
            setCollect(null);
            refresh();
          }}
        />
      )}

      <Modal
        open={!!voiding}
        onClose={() => setVoiding(null)}
        title={`إلغاء السند ${voiding?.receipt_no ?? ""}`}
        size="sm"
        footer={
          <Button className="bg-red-600 hover:bg-red-700" onClick={doVoid} disabled={!voidReason.trim()}>
            إلغاء السند
          </Button>
        }
      >
        <p className="mb-2 text-sm text-slate-600">يُسجَّل قيد عكسي في الحساب، وإن كان نقدياً من الدرج تُسجَّل حركة عكسية في الوردية.</p>
        <Field label="السبب *">
          <Textarea value={voidReason} onChange={(e) => setVoidReason(e.target.value)} />
        </Field>
      </Modal>

      <Modal
        open={limitOpen}
        onClose={() => setLimitOpen(false)}
        title="حد الائتمان (البيع الآجل)"
        size="sm"
        footer={<Button onClick={saveLimit}>حفظ</Button>}
      >
        <Field label="الحد الأقصى للمستحق على العميل (ر.س)" hint="اتركه فارغاً لإيقاف البيع الآجل لهذا العميل">
          <Input type="number" min={0} step="0.01" value={limit} onChange={(e) => setLimit(e.target.value)} />
        </Field>
      </Modal>

      {printing && st && (
        <PrintPortal>
          <div className="statement-print" dir="rtl" style={{ padding: "8mm", fontSize: 12 }}>
            <h2 style={{ fontSize: 16, fontWeight: 700 }}>{settings.store_name} — كشف حساب عميل</h2>
            <p>
              {customer.name} {customer.phone ? `· ${customer.phone}` : ""} · الفترة: {st.from ?? "البداية"} — {st.to} · طُبع بواسطة {profile.full_name}
            </p>
            <StatementTable st={st} print />
            <p style={{ marginTop: 8, fontWeight: 700 }}>الرصيد الختامي: {money(st.closing_balance)}</p>
          </div>
        </PrintPortal>
      )}
    </div>
  );
}

function StatementTable({ st, print = false }: { st: CustomerStatement; print?: boolean }) {
  const body = (
    <>
      <thead>
        <tr>
          <th>التاريخ</th>
          <th>البيان</th>
          <th>المرجع</th>
          <th>مدين</th>
          <th>دائن</th>
          <th>الرصيد</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>—</td>
          <td>رصيد أول المدة</td>
          <td></td>
          <td></td>
          <td></td>
          <td className="tabular-nums">{money(st.opening_balance)}</td>
        </tr>
        {st.entries.map((e) => (
          <tr key={e.id}>
            <td className="ltr-nums">{print ? dateOnly(e.date) : dateTime(e.date)}</td>
            <td>
              {AR_ENTRY_LABELS[e.type]}
              {e.note ? ` — ${e.note}` : ""}
            </td>
            <td dir="ltr">{e.ref_no}</td>
            <td className="tabular-nums">{Number(e.debit) > 0 ? money(e.debit) : ""}</td>
            <td className="tabular-nums">{Number(e.credit) > 0 ? money(e.credit) : ""}</td>
            <td className="font-medium tabular-nums">{money(e.balance)}</td>
          </tr>
        ))}
      </tbody>
    </>
  );
  if (print) return <table style={{ width: "100%", marginTop: 8, borderCollapse: "collapse" }}>{body}</table>;
  return <Table>{body}</Table>;
}

function CollectionModal({
  customer,
  kind,
  maxRefund,
  isManager,
  onClose,
  onDone,
  reservationId,
}: {
  customer: Customer;
  kind: "receipt" | "refund";
  maxRefund: number;
  isManager: boolean;
  onClose: () => void;
  onDone: () => void;
  reservationId?: string;
}) {
  const toast = useToast();
  const [amount, setAmount] = useState(kind === "refund" ? maxRefund.toFixed(2) : "");
  const [method, setMethod] = useState<CollectionMethod>("cash_drawer");
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  // نفس المفتاح طوال عمر النافذة: الضغط المزدوج أو إعادة المحاولة لا تُنشئ سنداً ثانياً
  const [clientRef] = useState(newClientRef);

  const methods = (Object.keys(COLLECTION_METHOD_LABELS) as CollectionMethod[]).filter((m) => m !== "cash" || isManager);

  const submit = async () => {
    const value = Number(amount);
    if (!(value > 0)) return toast("أدخل المبلغ", "error");
    setBusy(true);
    const { error } = await supabase().rpc("record_customer_payment", {
      p_customer_id: customer.id,
      p_amount: value,
      p_method: method,
      p_kind: kind,
      p_reference: reference || null,
      p_notes: notes || null,
      p_client_ref: clientRef,
      p_reservation_id: reservationId ?? null,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast(kind === "receipt" ? "تم تسجيل التحصيل" : "تم رد الرصيد للعميل");
    onDone();
  };

  return (
    <Modal
      open
      onClose={onClose}
      title={kind === "receipt" ? (reservationId ? "عربون الحجز" : `تحصيل من ${customer.name}`) : `رد رصيد لـ ${customer.name}`}
      size="sm"
      footer={
        <Button onClick={submit} loading={busy}>
          {kind === "receipt" ? "تسجيل التحصيل" : "رد الرصيد"}
        </Button>
      }
    >
      <div className="space-y-3">
        <Field label="المبلغ (ر.س)" hint={kind === "refund" ? `الحد الأقصى ${money(maxRefund)}` : undefined}>
          <Input type="number" inputMode="decimal" min={0} step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus aria-label="مبلغ التحصيل" />
        </Field>
        <Field label="الطريقة">
          <Select value={method} onChange={(e) => setMethod(e.target.value as CollectionMethod)} aria-label="طريقة التحصيل">
            {methods.map((m) => (
              <option key={m} value={m}>
                {COLLECTION_METHOD_LABELS[m]}
              </option>
            ))}
          </Select>
        </Field>
        {method !== "cash_drawer" && method !== "cash" && (
          <Field label="المرجع">
            <Input value={reference} onChange={(e) => setReference(e.target.value)} />
          </Field>
        )}
        <Field label="ملاحظات">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
        {method === "cash_drawer" && <p className="text-xs text-slate-500">يُسجَّل تلقائياً كإيداع في درج ورديتك المفتوحة.</p>}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- النقاط
function Loyalty({ p, onChanged }: { p: Profile; onChanged: () => void }) {
  const toast = useToast();
  const { isManager, settings } = useSession();
  const [open, setOpen] = useState(false);
  const [points, setPoints] = useState("");
  const [reason, setReason] = useState("");

  const save = async () => {
    const n = Math.trunc(Number(points));
    if (!n || !reason.trim()) return toast("أدخل النقاط (+/−) والسبب", "error");
    const { error } = await supabase().rpc("adjust_loyalty", { p_customer_id: p.customer.id, p_points: n, p_reason: reason.trim() });
    if (error) return toast(errorMessage(error), "error");
    toast("تم تعديل النقاط");
    setOpen(false);
    setPoints("");
    setReason("");
    onChanged();
  };

  return (
    <Card>
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-slate-100 p-3">
        <p className="text-sm text-slate-600">
          {settings.loyalty_enabled
            ? `كل 1 ر.س مدفوع = ${settings.loyalty_points_per_sar} نقطة · النقطة = ${Number(settings.loyalty_point_value).toFixed(2)} ر.س · الحد الأدنى للاستبدال ${settings.loyalty_min_redeem}`
            : "برنامج الولاء غير مفعّل (من الإعدادات)"}
        </p>
        {isManager && (
          <Button variant="outline" size="sm" onClick={() => setOpen(true)}>
            تعديل يدوي
          </Button>
        )}
      </div>
      {p.loyalty.length === 0 ? (
        <EmptyState title="لا توجد حركات نقاط" />
      ) : (
        <Table>
          <thead>
            <tr>
              <th>التاريخ</th>
              <th>الحركة</th>
              <th>المرجع</th>
              <th>النقاط</th>
              <th>الرصيد</th>
            </tr>
          </thead>
          <tbody>
            {p.loyalty.map((l) => (
              <tr key={l.id}>
                <td className="ltr-nums text-slate-600">{dateTime(l.created_at)}</td>
                <td>
                  {LOYALTY_ENTRY_LABELS[l.entry_type]}
                  {l.note ? ` — ${l.note}` : ""}
                </td>
                <td dir="ltr">{l.ref_no}</td>
                <td className={cn("font-semibold tabular-nums", l.points > 0 ? "text-emerald-700" : "text-red-600")}>
                  {l.points > 0 ? `+${l.points}` : l.points}
                </td>
                <td className="tabular-nums">{l.balance_after}</td>
              </tr>
            ))}
          </tbody>
        </Table>
      )}
      <Modal open={open} onClose={() => setOpen(false)} title="تعديل النقاط" size="sm" footer={<Button onClick={save}>حفظ</Button>}>
        <div className="space-y-3">
          <Field label="النقاط (موجب للإضافة، سالب للخصم)">
            <Input type="number" value={points} onChange={(e) => setPoints(e.target.value)} />
          </Field>
          <Field label="السبب *">
            <Input value={reason} onChange={(e) => setReason(e.target.value)} />
          </Field>
        </div>
      </Modal>
    </Card>
  );
}

// ---------------------------------------------------------------- الحجوزات
function Reservations({
  p,
  phone,
  onChanged,
  onFulfil,
}: {
  p: Profile;
  phone: string | null;
  onChanged: () => void;
  onFulfil: (id: string) => void;
}) {
  const toast = useToast();
  const { settings } = useSession();
  const [deposit, setDeposit] = useState<string | null>(null);

  const cancel = async (id: string) => {
    const reason = window.prompt("سبب إلغاء الحجز");
    if (!reason?.trim()) return;
    const { error } = await supabase().rpc("cancel_reservation", { p_reservation_id: id, p_reason: reason.trim() });
    if (error) return toast(errorMessage(error), "error");
    toast("تم إلغاء الحجز");
    onChanged();
  };
  const extend = async (id: string) => {
    const { error } = await supabase().rpc("extend_reservation", { p_reservation_id: id, p_days: settings.reservation_days });
    if (error) return toast(errorMessage(error), "error");
    toast(`تم التمديد ${settings.reservation_days} أيام`);
    onChanged();
  };

  if (p.reservations.length === 0)
    return (
      <Card>
        <EmptyState title="لا توجد حجوزات">
          <Link href={`/reservations?customer=${p.customer.id}`} className="text-brand-700 hover:underline">
            إنشاء حجز
          </Link>
        </EmptyState>
      </Card>
    );
  return (
    <div className="space-y-3">
      {p.reservations.map((r) => {
        const st = reservationState({ status: r.status, expires_at: r.expires_at });
        return (
          <Card key={r.id} className="p-4">
            <div className="flex flex-wrap items-center gap-2">
              <p className="font-semibold" dir="ltr">{r.reservation_no}</p>
              <Badge tone={st.tone}>{st.label}</Badge>
              <p className="text-xs text-slate-500">حتى {dateTime(r.expires_at)}</p>
              {r.status === "active" && (
                <div className="ms-auto flex flex-wrap gap-2">
                  <Button size="sm" onClick={() => onFulfil(r.id)}>
                    استلام في نقطة البيع
                  </Button>
                  <Button size="sm" variant="outline" onClick={() => setDeposit(r.id)}>
                    عربون
                  </Button>
                  <Button size="sm" variant="outline" onClick={() => extend(r.id)}>
                    تمديد
                  </Button>
                  {phone && (
                    <Button
                      size="sm"
                      variant="outline"
                      className="border-emerald-600 text-emerald-700"
                      onClick={() =>
                        openWhatsApp({
                          phone,
                          kind: "reservation",
                          customerId: p.customer.id,
                          reservationId: r.id,
                          text: [
                            `مرحباً ${p.customer.name}،`,
                            `حجزك رقم ${r.reservation_no} لدى ${settings.store_name} جاهز للاستلام:`,
                            ...(r.items ?? []).map((i) => `• ${i.product_name}${i.variant_label ? ` (${i.variant_label})` : ""} × ${i.qty}`),
                            `الحجز ساري حتى ${dateTime(r.expires_at)}.`,
                          ].join("\n"),
                        }).catch((e) => toast(errorMessage(e), "error"))
                      }
                    >
                      <MessageCircle className="size-4" />
                    </Button>
                  )}
                  <Button size="sm" variant="ghost" className="text-red-600" onClick={() => cancel(r.id)}>
                    إلغاء
                  </Button>
                </div>
              )}
            </div>
            <ul className="mt-2 text-sm text-slate-700">
              {(r.items ?? []).map((i) => (
                <li key={i.variant_id}>
                  {i.product_name} {i.variant_label && <span className="text-slate-500">({i.variant_label})</span>} × {i.qty}
                </li>
              ))}
            </ul>
            {r.notes && <p className="mt-1 text-xs text-slate-500">{r.notes}</p>}
          </Card>
        );
      })}
      {deposit && (
        <CollectionModal
          customer={p.customer}
          kind="receipt"
          maxRefund={0}
          isManager={false}
          reservationId={deposit}
          onClose={() => setDeposit(null)}
          onDone={() => {
            setDeposit(null);
            onChanged();
          }}
        />
      )}
    </div>
  );
}
