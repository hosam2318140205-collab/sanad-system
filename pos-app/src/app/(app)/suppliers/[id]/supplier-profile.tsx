"use client";

import { ArrowRight, Banknote, FileMinus2, Printer, Undo2, Wallet } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Stat, Table, Textarea, cn, useToast } from "@/components/ui";
import { dateOnly, errorMessage, money, variantLabel } from "@/lib/format";
import { fetchLocations, newRef, type Location } from "@/lib/inventory";
import {
  CREDIT_KIND_LABELS,
  ENTRY_LABELS,
  METHOD_LABELS,
  RETURN_STATUS,
  type ApPaymentMethod,
  type OpenDocument,
  type StatementRow,
} from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";
import type { Supplier } from "@/lib/types";

type Tab = "statement" | "open" | "payments" | "returns" | "credits" | "prices";

interface Profile {
  supplier: Supplier;
  balance: number;
  open_total: number;
  overdue_total: number;
  unapplied_payments: number;
  invoiced_12m: number;
  paid_12m: number;
  last_payment: { payment_no: string; amount: number; paid_at: string } | null;
  over_credit_limit: boolean;
}

interface Payment {
  id: string;
  payment_no: string;
  amount: number;
  allocated_amount: number;
  method: ApPaymentMethod;
  reference: string | null;
  paid_at: string;
  is_void: boolean;
  void_reason: string | null;
}

interface ReturnRow {
  id: string;
  return_no: string;
  status: string;
  reason: string;
  created_at: string;
  location: { name: string } | null;
  items: Array<{ qty: number; unit_cost: number }>;
}

interface CreditRow {
  id: string;
  cn_no: string;
  kind: string;
  status: string;
  supplier_credit_no: string | null;
  credit_date: string;
  total: number;
  allocated_amount: number;
}

interface PricePoint {
  supplier_id: string;
  sku: string;
  doc_no: string;
  invoice_date: string;
  qty: number;
  unit_cost: number;
  landed_unit: number;
  change_pct: number | null;
}

const n = (v: unknown) => Number(v ?? 0) || 0;

export function SupplierProfile({ id }: { id: string }) {
  const toast = useToast();
  const { isOwner } = useSession();
  const [p, setP] = useState<Profile | null>(null);
  const [tab, setTab] = useState<Tab>("statement");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [statement, setStatement] = useState<StatementRow[] | null>(null);
  const [openDocs, setOpenDocs] = useState<OpenDocument[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [returns, setReturns] = useState<ReturnRow[]>([]);
  const [credits, setCredits] = useState<CreditRow[]>([]);
  const [prices, setPrices] = useState<PricePoint[]>([]);
  const [modal, setModal] = useState<"payment" | "credit" | "return" | "refund" | "opening" | null>(null);
  const [voiding, setVoiding] = useState<{ kind: "payment" | "credit"; id: string; no: string } | null>(null);

  const load = useCallback(async () => {
    const db = supabase();
    try {
      const [{ data: prof, error }, od, pays, rets, cns, hist] = await Promise.all([
        db.rpc("supplier_profile", { p_supplier: id }),
        db.rpc("supplier_open_documents", { p_supplier: id }),
        db.from("supplier_payments").select("*").eq("supplier_id", id).order("paid_at", { ascending: false }).order("created_at", { ascending: false }).limit(200),
        db.from("supplier_returns").select("id, return_no, status, reason, created_at, location:locations(name), items:supplier_return_items(qty, unit_cost)")
          .eq("supplier_id", id).order("created_at", { ascending: false }).limit(100),
        db.from("supplier_credit_notes").select("*").eq("supplier_id", id).order("created_at", { ascending: false }).limit(100),
        db.rpc("supplier_price_history", { p_variant: null, p_product: null, p_days: 365 }),
      ]);
      if (error) throw error;
      const pr = prof as Profile;
      setP({ ...pr, balance: n(pr.balance), open_total: n(pr.open_total), overdue_total: n(pr.overdue_total),
             unapplied_payments: n(pr.unapplied_payments), invoiced_12m: n(pr.invoiced_12m), paid_12m: n(pr.paid_12m) });
      setOpenDocs(((od.data ?? []) as OpenDocument[]).map((d) => ({ ...d, total: n(d.total), outstanding: n(d.outstanding), settled: n(d.settled) })));
      setPayments(((pays.data ?? []) as Payment[]).map((x) => ({ ...x, amount: n(x.amount), allocated_amount: n(x.allocated_amount) })));
      setReturns((rets.data ?? []) as unknown as ReturnRow[]);
      setCredits(((cns.data ?? []) as CreditRow[]).map((c) => ({ ...c, total: n(c.total), allocated_amount: n(c.allocated_amount) })));
      setPrices(((hist.data ?? []) as PricePoint[]).filter((h) => h.supplier_id === id));
    } catch (e) {
      toast(errorMessage(e), "error");
    }
  }, [id, toast]);

  const loadStatement = useCallback(async () => {
    const { data, error } = await supabase().rpc("supplier_statement", { p_supplier: id, p_from: from || null, p_to: to || null });
    if (error) return toast(errorMessage(error), "error");
    setStatement(((data ?? []) as StatementRow[]).map((r) => ({ ...r, debit: n(r.debit), credit: n(r.credit), balance: n(r.balance) })));
  }, [id, from, to, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reload on filter change
    loadStatement();
  }, [loadStatement]);

  const refresh = () => {
    setModal(null);
    setVoiding(null);
    load();
    loadStatement();
  };

  if (!p) return <Loading />;
  const s = p.supplier;
  const unappliedCredits = credits.filter((c) => c.status === "posted").reduce((a, c) => a + c.total - c.allocated_amount, 0);
  const unapplied = p.unapplied_payments + unappliedCredits;
  const hasOpening = statement?.some((r) => r.entry_type === "opening") ?? true;

  const tabs: Array<[Tab, string]> = [
    ["statement", "كشف الحساب"],
    ["open", `المستحق (${openDocs.length})`],
    ["payments", "الدفعات"],
    ["returns", "المرتجعات"],
    ["credits", "الإشعارات الدائنة"],
    ["prices", "تاريخ الأسعار"],
  ];

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={s.name}
        subtitle={[s.code, s.payment_terms_days ? `سداد ${s.payment_terms_days} يوماً` : "نقدي", s.vat_registered === false ? "غير مسجل ضريبياً" : null]
          .filter(Boolean)
          .join(" · ")}
        actions={
          <>
            <Link href="/suppliers">
              <Button variant="ghost">
                <ArrowRight className="size-4" /> رجوع
              </Button>
            </Link>
            <Button onClick={() => setModal("payment")}>
              <Wallet className="size-4" /> دفعة
            </Button>
            <Button variant="outline" onClick={() => setModal("return")}>
              <Undo2 className="size-4" /> مرتجع
            </Button>
            <Button variant="outline" onClick={() => setModal("credit")}>
              <FileMinus2 className="size-4" /> إشعار دائن
            </Button>
            {unapplied > 0 && (
              <Button variant="outline" onClick={() => setModal("refund")}>
                <Banknote className="size-4" /> استرداد
              </Button>
            )}
            {isOwner && !hasOpening && (
              <Button variant="ghost" onClick={() => setModal("opening")}>
                رصيد افتتاحي
              </Button>
            )}
          </>
        }
      />

      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Stat label="الرصيد (علينا)" value={money(p.balance)} tone={p.balance > 0 ? "amber" : p.balance < 0 ? "green" : "slate"}
              hint={p.balance < 0 ? "مقدّم لدى المورد" : p.over_credit_limit ? "تجاوز حد الائتمان" : undefined} />
        <Stat label="المستحق المفتوح" value={money(p.open_total)} />
        <Stat label="المتأخر" value={money(p.overdue_total)} tone={p.overdue_total > 0 ? "red" : "slate"} />
        <Stat label="رصيد دائن غير مطبق" value={money(unapplied)} tone={unapplied > 0 ? "green" : "slate"} />
        <Stat label="مشتريات 12 شهراً" value={money(p.invoiced_12m)} hint={`مدفوع ${money(p.paid_12m)}`} />
      </div>

      <div className="mb-4 flex gap-1 overflow-x-auto rounded-xl bg-slate-100 p-1 scrollbar-thin">
        {tabs.map(([k, label]) => (
          <button
            key={k}
            type="button"
            onClick={() => setTab(k)}
            className={cn("shrink-0 rounded-lg px-3 py-2 text-sm font-medium", tab === k ? "bg-white text-slate-900 shadow-sm" : "text-slate-600")}
          >
            {label}
          </button>
        ))}
      </div>

      {tab === "statement" && (
        <Card>
          <div className="no-print flex flex-wrap items-end gap-2 border-b border-slate-100 p-3">
            <Field label="من">
              <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
            </Field>
            <Field label="إلى">
              <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
            </Field>
            <Button variant="outline" onClick={() => window.print()}>
              <Printer className="size-4" /> طباعة
            </Button>
          </div>
          {statement === null ? (
            <Loading />
          ) : statement.length === 0 ? (
            <EmptyState title="لا توجد حركات" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>التاريخ</th>
                  <th>البيان</th>
                  <th>المرجع</th>
                  <th>مدين (ينقص)</th>
                  <th>دائن (يزيد)</th>
                  <th>الرصيد</th>
                </tr>
              </thead>
              <tbody>
                {statement.map((r, i) => (
                  <tr key={r.entry_id ?? `open-${i}`} className={cn(r.entry_id === null && "bg-slate-50 font-medium")}>
                    <td className="ltr-nums">{dateOnly(r.entry_date)}</td>
                    <td>
                      {r.entry_type ? ENTRY_LABELS[r.entry_type] : r.ref_no}
                      {r.note && <span className="block text-xs text-slate-500">{r.note}</span>}
                    </td>
                    <td className="ltr-nums text-xs">{r.entry_type ? r.ref_no : ""}</td>
                    <td>{r.debit ? money(r.debit) : ""}</td>
                    <td>{r.credit ? money(r.credit) : ""}</td>
                    <td className="font-semibold">{money(r.balance)}</td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "open" && (
        <Card>
          {openDocs.length === 0 ? (
            <EmptyState title="لا توجد مستحقات مفتوحة" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>المستند</th>
                  <th>فاتورة المورد</th>
                  <th>التاريخ</th>
                  <th>الاستحقاق</th>
                  <th>الإجمالي</th>
                  <th>المسدَّد</th>
                  <th>المتبقي</th>
                </tr>
              </thead>
              <tbody>
                {openDocs.map((d) => (
                  <tr key={d.invoice_id}>
                    <td>
                      <Link href={`/purchases/invoices/${d.invoice_id}`} className="ltr-nums font-medium text-brand-700 hover:underline">
                        {d.doc_no}
                      </Link>
                    </td>
                    <td className="ltr-nums">{d.supplier_invoice_no ?? (d.kind === "opening" ? "رصيد افتتاحي" : "-")}</td>
                    <td className="ltr-nums">{dateOnly(d.invoice_date)}</td>
                    <td>
                      <span className="ltr-nums">{d.due_date ? dateOnly(d.due_date) : "-"}</span>{" "}
                      {d.days_overdue > 0 && <Badge tone="red">متأخرة {d.days_overdue} يوماً</Badge>}
                    </td>
                    <td>{money(d.total)}</td>
                    <td>{money(d.settled)}</td>
                    <td className="font-semibold">{money(d.outstanding)}</td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "payments" && (
        <Card>
          {payments.length === 0 ? (
            <EmptyState title="لا توجد دفعات" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>الرقم</th>
                  <th>التاريخ</th>
                  <th>الطريقة</th>
                  <th>المبلغ</th>
                  <th>غير موزع (مقدّم)</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {payments.map((x) => (
                  <tr key={x.id} className={cn(x.is_void && "text-slate-400 line-through")}>
                    <td className="ltr-nums font-medium">{x.payment_no}</td>
                    <td className="ltr-nums">{dateOnly(x.paid_at)}</td>
                    <td>
                      {METHOD_LABELS[x.method]}
                      {x.reference && <span className="ltr-nums block text-xs text-slate-500">{x.reference}</span>}
                    </td>
                    <td>{money(x.amount)}</td>
                    <td>{!x.is_void && x.amount > x.allocated_amount ? money(x.amount - x.allocated_amount) : "-"}</td>
                    <td>
                      {!x.is_void && x.method !== "opening" && (
                        <Button size="sm" variant="ghost" onClick={() => setVoiding({ kind: "payment", id: x.id, no: x.payment_no })}>
                          إلغاء
                        </Button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "returns" && <ReturnsList rows={returns} supplierId={id} onChange={refresh} />}

      {tab === "credits" && (
        <Card>
          {credits.length === 0 ? (
            <EmptyState title="لا توجد إشعارات دائنة" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>الرقم</th>
                  <th>النوع</th>
                  <th>مرجع المورد</th>
                  <th>التاريخ</th>
                  <th>الإجمالي</th>
                  <th>غير مطبق</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {credits.map((c) => (
                  <tr key={c.id} className={cn(c.status === "void" && "text-slate-400 line-through")}>
                    <td className="ltr-nums font-medium">{c.cn_no}</td>
                    <td>{CREDIT_KIND_LABELS[c.kind]}</td>
                    <td className="ltr-nums">{c.supplier_credit_no ?? "-"}</td>
                    <td className="ltr-nums">{dateOnly(c.credit_date)}</td>
                    <td>{money(c.total)}</td>
                    <td>{c.status === "posted" && c.total > c.allocated_amount ? money(c.total - c.allocated_amount) : "-"}</td>
                    <td>
                      {c.status === "posted" && (
                        <Button size="sm" variant="ghost" onClick={() => setVoiding({ kind: "credit", id: c.id, no: c.cn_no })}>
                          إلغاء
                        </Button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "prices" && (
        <Card>
          {prices.length === 0 ? (
            <EmptyState title="لا توجد فواتير شراء مرحّلة بعد" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>التاريخ</th>
                  <th>الصنف</th>
                  <th>الفاتورة</th>
                  <th>الكمية</th>
                  <th>السعر</th>
                  <th>التكلفة الواصلة</th>
                  <th>التغير</th>
                </tr>
              </thead>
              <tbody>
                {prices.map((h, i) => (
                  <tr key={`${h.doc_no}-${h.sku}-${i}`}>
                    <td className="ltr-nums">{dateOnly(h.invoice_date)}</td>
                    <td className="ltr-nums">{h.sku}</td>
                    <td className="ltr-nums text-xs">{h.doc_no}</td>
                    <td>{h.qty}</td>
                    <td>{money(h.unit_cost)}</td>
                    <td>{money(h.landed_unit)}</td>
                    <td>
                      {h.change_pct === null ? "-" : (
                        <Badge tone={n(h.change_pct) >= 10 ? "red" : n(h.change_pct) > 0 ? "amber" : "green"}>
                          {n(h.change_pct) > 0 ? "+" : ""}
                          {h.change_pct}%
                        </Badge>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      )}

      {modal === "payment" && <PaymentModal supplier={s} openDocs={openDocs} onClose={() => setModal(null)} onDone={refresh} />}
      {modal === "credit" && <CreditModal supplierId={id} onClose={() => setModal(null)} onDone={refresh} />}
      {modal === "return" && <ReturnModal supplierId={id} onClose={() => setModal(null)} onDone={refresh} />}
      {modal === "refund" && <RefundModal supplierId={id} max={unapplied} onClose={() => setModal(null)} onDone={refresh} />}
      {modal === "opening" && <OpeningModal supplierId={id} onClose={() => setModal(null)} onDone={refresh} />}
      {voiding && (
        <ReasonModal
          title={`إلغاء ${voiding.no}`}
          onClose={() => setVoiding(null)}
          onSubmit={async (reason) => {
            const { error } = voiding.kind === "payment"
              ? await supabase().rpc("void_supplier_payment", { p_id: voiding.id, p_reason: reason })
              : await supabase().rpc("void_credit_note", { p_id: voiding.id, p_reason: reason });
            if (error) return toast(errorMessage(error), "error");
            toast("تم الإلغاء بقيد عكسي");
            refresh();
          }}
        />
      )}
    </div>
  );
}

function ReasonModal({ title, onClose, onSubmit }: { title: string; onClose: () => void; onSubmit: (reason: string) => Promise<void> }) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <Modal
      open
      onClose={onClose}
      title={title}
      size="sm"
      footer={
        <Button variant="danger" disabled={!reason.trim()} loading={busy} onClick={async () => (setBusy(true), await onSubmit(reason.trim()), setBusy(false))}>
          تأكيد
        </Button>
      }
    >
      <Field label="السبب (إلزامي)">
        <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
    </Modal>
  );
}

function PaymentModal({ supplier, openDocs, onClose, onDone }: { supplier: Supplier; openDocs: OpenDocument[]; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const { isManager } = useSession();
  const [amount, setAmount] = useState(String(openDocs.reduce((a, d) => a + d.outstanding, 0) || ""));
  const [method, setMethod] = useState<ApPaymentMethod>("bank_transfer");
  const [reference, setReference] = useState("");
  const [paidAt, setPaidAt] = useState(new Date().toISOString().slice(0, 10));
  const [mode, setMode] = useState<"auto" | "manual">("auto");
  const [alloc, setAlloc] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());

  const total = Number(amount) || 0;
  const manualSum = Object.values(alloc).reduce((a, v) => a + (Number(v) || 0), 0);
  const submit = async () => {
    if (total <= 0) return toast("أدخل المبلغ", "error");
    if (mode === "manual" && manualSum > total + 0.001) return toast("مجموع التوزيع أكبر من المبلغ", "error");
    setBusy(true);
    const allocations = mode === "manual"
      ? Object.entries(alloc).filter(([, v]) => Number(v) > 0).map(([invoice_id, v]) => ({ invoice_id, amount: Number(v) }))
      : null;
    const { error } = await supabase().rpc("post_supplier_payment", {
      p_supplier: supplier.id,
      p_amount: total,
      p_method: method,
      p_reference: reference || null,
      p_paid_at: paidAt,
      p_allocations: allocations,
      p_notes: notes || null,
      p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم تسجيل الدفعة");
    onDone();
  };

  return (
    <Modal open onClose={onClose} title={`دفعة إلى ${supplier.name}`} size="lg" footer={<Button onClick={submit} loading={busy}>تسجيل الدفعة</Button>}>
      <div className="space-y-3">
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="المبلغ">
            <Input type="number" step="0.01" min={0} value={amount} onChange={(e) => setAmount(e.target.value)} />
          </Field>
          <Field label="الطريقة">
            <Select value={method} onChange={(e) => setMethod(e.target.value as ApPaymentMethod)}>
              {(["bank_transfer", "cash", "cheque", "card", "cash_drawer"] as ApPaymentMethod[])
                .filter((m) => m !== "cash_drawer" || isManager)
                .map((m) => (
                  <option key={m} value={m}>
                    {METHOD_LABELS[m]}
                  </option>
                ))}
            </Select>
          </Field>
          <Field label="التاريخ">
            <Input type="date" value={paidAt} onChange={(e) => setPaidAt(e.target.value)} />
          </Field>
        </div>
        {(method === "bank_transfer" || method === "cheque") && (
          <Field label={method === "cheque" ? "رقم الشيك" : "رقم الحوالة"}>
            <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} />
          </Field>
        )}
        {method === "cash_drawer" && <p className="rounded-lg bg-amber-50 p-2 text-xs text-amber-800">يُسحب من درج ورديتك المفتوحة ويظهر في تقرير الوردية.</p>}
        <Field label="التوزيع على الفواتير">
          <Select value={mode} onChange={(e) => setMode(e.target.value as typeof mode)}>
            <option value="auto">تلقائي: الأقدم استحقاقاً أولاً</option>
            <option value="manual">يدوي</option>
          </Select>
        </Field>
        {mode === "manual" && (
          <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200">
            {openDocs.map((d) => (
              <li key={d.invoice_id} className="flex items-center gap-3 p-2 text-sm">
                <span className="min-w-0 flex-1">
                  <span className="ltr-nums font-medium">{d.supplier_invoice_no ?? d.doc_no}</span> — المتبقي {money(d.outstanding)}
                  {d.days_overdue > 0 && <span className="text-red-600"> (متأخرة {d.days_overdue} يوماً)</span>}
                </span>
                <Input
                  type="number"
                  step="0.01"
                  min={0}
                  max={d.outstanding}
                  aria-label={`توزيع ${d.doc_no}`}
                  className="h-9 w-28"
                  value={alloc[d.invoice_id] ?? ""}
                  onChange={(e) => setAlloc((a) => ({ ...a, [d.invoice_id]: e.target.value }))}
                />
              </li>
            ))}
          </ul>
        )}
        <p className="text-xs text-slate-500">
          {mode === "manual" ? `الموزع ${money(manualSum)} — ` : ""}ما يزيد عن المستحق يبقى دفعة مقدمة تُطبَّق لاحقاً على فواتير جديدة.
        </p>
        <Field label="ملاحظة">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
      </div>
    </Modal>
  );
}

interface ReceiptLine {
  id: string;
  variant_id: string;
  qty: number;
  qty_returned: number;
  unit_cost: number;
  receipt: { grn_no: string; received_at: string; location_id: string | null };
  variant: { sku: string; size: string | null; color: string | null; product: { name: string } };
}

function ReturnModal({ supplierId, onClose, onDone }: { supplierId: string; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [lines, setLines] = useState<ReceiptLine[] | null>(null);
  const [locations, setLocations] = useState<Location[]>([]);
  const [loc, setLoc] = useState("");
  const [qty, setQty] = useState<Record<string, string>>({});
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());

  useEffect(() => {
    fetchLocations().then((l) => {
      setLocations(l);
      setLoc(l[0]?.id ?? "");
    });
    supabase()
      .from("goods_receipt_items")
      .select("id, variant_id, qty, qty_returned, unit_cost, receipt:goods_receipts!inner(grn_no, received_at, location_id, supplier_id), variant:product_variants(sku, size, color, product:products(name))")
      .eq("receipt.supplier_id", supplierId)
      .order("id", { ascending: false })
      .limit(300)
      .then(({ data }) => setLines(((data ?? []) as unknown as ReceiptLine[]).filter((l) => l.qty > l.qty_returned)));
  }, [supplierId]);

  const shown = useMemo(() => (lines ?? []).filter((l) => !loc || (l.receipt.location_id ?? locations.find((x) => x.is_default)?.id) === loc), [lines, loc, locations]);

  const submit = async () => {
    const items = Object.entries(qty).filter(([, v]) => Number(v) > 0).map(([receipt_item_id, v]) => ({ receipt_item_id, qty: Number(v) }));
    if (!items.length) return toast("حدد كميات الإرجاع", "error");
    if (!reason.trim()) return toast("سبب الإرجاع مطلوب", "error");
    setBusy(true);
    const { error } = await supabase().rpc("create_supplier_return", {
      p_supplier: supplierId, p_location: loc, p_items: items, p_reason: reason.trim(), p_notes: null, p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم إنشاء المرتجع — اعتمده ثم اشحنه");
    onDone();
  };

  return (
    <Modal open onClose={onClose} title="مرتجع للمورد" size="lg" footer={<Button onClick={submit} loading={busy}>إنشاء المرتجع</Button>}>
      <div className="space-y-3">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="الموقع (يخرج من مخزونه)">
            <Select value={loc} onChange={(e) => setLoc(e.target.value)}>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="السبب">
            <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="عيب تصنيع / مقاس خاطئ" />
          </Field>
        </div>
        {lines === null ? (
          <Loading />
        ) : shown.length === 0 ? (
          <EmptyState title="لا توجد بضاعة مستلمة من هذا المورد في هذا الموقع" />
        ) : (
          <ul className="max-h-80 divide-y divide-slate-100 overflow-y-auto rounded-lg border border-slate-200">
            {shown.map((l) => (
              <li key={l.id} className="flex items-center gap-3 p-2 text-sm">
                <span className="min-w-0 flex-1">
                  <b>{l.variant.product.name}</b> {variantLabel(l.variant.size, l.variant.color)}
                  <span className="block text-xs text-slate-500">
                    <span className="ltr-nums">{l.receipt.grn_no}</span> · مستلم {l.qty}، أُرجع {l.qty_returned} · {money(l.unit_cost)}
                  </span>
                </span>
                <Input
                  type="number"
                  min={0}
                  max={l.qty - l.qty_returned}
                  aria-label={`إرجاع ${l.variant.sku}`}
                  className="h-9 w-20"
                  value={qty[l.id] ?? ""}
                  onChange={(e) => setQty((q) => ({ ...q, [l.id]: e.target.value }))}
                />
              </li>
            ))}
          </ul>
        )}
        <p className="text-xs text-slate-500">يُسعَّر بسعر فاتورة المورد الأصلية. لا يخرج من المخزون إلا عند الشحن، ولا أكثر من الموجود في الموقع.</p>
      </div>
    </Modal>
  );
}

function ReturnsList({ rows, supplierId, onChange }: { rows: ReturnRow[]; supplierId: string; onChange: () => void }) {
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const act = async (fn: string, args: Record<string, unknown>, ok: string, key: string) => {
    setBusy(key);
    const { error } = await supabase().rpc(fn, args);
    setBusy(null);
    if (error) return toast(errorMessage(error), "error");
    toast(ok);
    onChange();
  };
  if (rows.length === 0) return <Card><EmptyState title="لا توجد مرتجعات" /></Card>;
  return (
    <Card>
      <Table>
        <thead>
          <tr>
            <th>الرقم</th>
            <th>الموقع</th>
            <th>السبب</th>
            <th>القيمة</th>
            <th>الحالة</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const value = r.items.reduce((a, i) => a + i.qty * Number(i.unit_cost), 0);
            return (
              <tr key={r.id}>
                <td className="ltr-nums font-medium">{r.return_no}</td>
                <td>{r.location?.name}</td>
                <td className="max-w-xs whitespace-normal">{r.reason}</td>
                <td>{money(value)}</td>
                <td>
                  <Badge tone={RETURN_STATUS[r.status]?.tone ?? "slate"}>{RETURN_STATUS[r.status]?.label ?? r.status}</Badge>
                </td>
                <td className="space-x-1 whitespace-nowrap">
                  {r.status === "draft" && (
                    <Button size="sm" loading={busy === r.id + "a"} onClick={() => act("approve_supplier_return", { p_id: r.id }, "تم الاعتماد", r.id + "a")}>
                      اعتماد
                    </Button>
                  )}
                  {r.status === "approved" && (
                    <Button size="sm" loading={busy === r.id + "s"} onClick={() => act("ship_supplier_return", { p_id: r.id, p_client_ref: newRef() }, "تم الشحن وخصم المخزون", r.id + "s")}>
                      شحن
                    </Button>
                  )}
                  {r.status === "shipped" && (
                    <Button size="sm" loading={busy === r.id + "c"}
                      onClick={() => act("post_credit_note", {
                        p_supplier: supplierId, p_kind: "return", p_return_id: r.id, p_invoice_id: null, p_supplier_credit_no: null,
                        p_credit_date: null, p_lines: null, p_allocations: null, p_notes: null, p_client_ref: newRef(),
                      }, "صدر الإشعار الدائن وخُصم من المستحق", r.id + "c")}>
                      إشعار دائن
                    </Button>
                  )}
                  {(r.status === "draft" || r.status === "approved") && (
                    <Button size="sm" variant="ghost" onClick={() => act("cancel_supplier_return", { p_id: r.id, p_reason: "إلغاء من الشاشة" }, "تم الإلغاء", r.id + "x")}>
                      إلغاء
                    </Button>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </Card>
  );
}

function CreditModal({ supplierId, onClose, onDone }: { supplierId: string; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [kind, setKind] = useState<"price" | "rebate">("rebate");
  const [ref_no, setRefNo] = useState("");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [desc, setDesc] = useState("");
  const [amount, setAmount] = useState("");
  const [lines, setLines] = useState<ReceiptLine[]>([]);
  const [line, setLine] = useState("");
  const [qty, setQty] = useState("");
  const [unit, setUnit] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());

  useEffect(() => {
    supabase()
      .from("goods_receipt_items")
      .select("id, variant_id, qty, qty_returned, unit_cost, receipt:goods_receipts!inner(grn_no, received_at, location_id, supplier_id), variant:product_variants(sku, size, color, product:products(name))")
      .eq("receipt.supplier_id", supplierId)
      .order("id", { ascending: false })
      .limit(200)
      .then(({ data }) => setLines((data ?? []) as unknown as ReceiptLine[]));
  }, [supplierId]);

  const submit = async () => {
    const p_lines = kind === "rebate"
      ? [{ description: desc.trim(), amount: Number(amount) }]
      : [{ receipt_item_id: line, qty: Number(qty), unit_amount: Number(unit) }];
    setBusy(true);
    const { error } = await supabase().rpc("post_credit_note", {
      p_supplier: supplierId, p_kind: kind, p_return_id: null, p_invoice_id: null, p_supplier_credit_no: ref_no || null,
      p_credit_date: date, p_lines, p_allocations: null, p_notes: null, p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم ترحيل الإشعار الدائن");
    onDone();
  };

  return (
    <Modal open onClose={onClose} title="إشعار دائن من المورد" size="md" footer={<Button onClick={submit} loading={busy}>ترحيل</Button>}>
      <div className="space-y-3">
        <Field label="النوع">
          <Select value={kind} onChange={(e) => setKind(e.target.value as typeof kind)}>
            <option value="rebate">خصم تجاري / كمية (لا يغيّر التكلفة)</option>
            <option value="price">تخفيض سعر على بضاعة مستلمة (يخفض التكلفة)</option>
          </Select>
        </Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="رقم إشعار المورد">
            <Input dir="ltr" value={ref_no} onChange={(e) => setRefNo(e.target.value)} />
          </Field>
          <Field label="التاريخ">
            <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </Field>
        </div>
        {kind === "rebate" ? (
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="الوصف">
              <Input value={desc} onChange={(e) => setDesc(e.target.value)} />
            </Field>
            <Field label="المبلغ قبل الضريبة">
              <Input type="number" step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </Field>
          </div>
        ) : (
          <>
            <Field label="سطر الاستلام">
              <Select value={line} onChange={(e) => setLine(e.target.value)}>
                <option value="">اختر</option>
                {lines.map((l) => (
                  <option key={l.id} value={l.id}>
                    {l.receipt.grn_no} — {l.variant.product.name} {variantLabel(l.variant.size, l.variant.color)} ({l.qty} × {money(l.unit_cost)})
                  </option>
                ))}
              </Select>
            </Field>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الكمية">
                <Input type="number" min={1} value={qty} onChange={(e) => setQty(e.target.value)} />
              </Field>
              <Field label="التخفيض للقطعة (قبل الضريبة)">
                <Input type="number" step="0.01" value={unit} onChange={(e) => setUnit(e.target.value)} />
              </Field>
            </div>
          </>
        )}
        <p className="text-xs text-slate-500">
          تُضاف الضريبة العكسية تلقائياً (للمورد المسجل)، ويُطبَّق على أقدم فاتورة مفتوحة، والباقي رصيد دائن لدى المورد.
          {kind === "price" && " نصيب الكمية الموجودة يخفض متوسط التكلفة، ونصيب ما بيع يُسجَّل فرق تكلفة."}
        </p>
      </div>
    </Modal>
  );
}

function RefundModal({ supplierId, max, onClose, onDone }: { supplierId: string; max: number; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [amount, setAmount] = useState(String(max));
  const [method, setMethod] = useState<ApPaymentMethod>("bank_transfer");
  const [reference, setReference] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());
  const submit = async () => {
    setBusy(true);
    const { error } = await supabase().rpc("record_supplier_refund", {
      p_supplier: supplierId, p_amount: Number(amount), p_method: method, p_reference: reference || null,
      p_received_at: null, p_notes: null, p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم تسجيل الاسترداد");
    onDone();
  };
  return (
    <Modal open onClose={onClose} title="استرداد من المورد" size="sm" footer={<Button onClick={submit} loading={busy}>تسجيل</Button>}>
      <div className="space-y-3">
        <p className="text-sm text-slate-600">الرصيد الدائن غير المطبق: {money(max)}</p>
        <Field label="المبلغ">
          <Input type="number" step="0.01" max={max} value={amount} onChange={(e) => setAmount(e.target.value)} />
        </Field>
        <Field label="الطريقة">
          <Select value={method} onChange={(e) => setMethod(e.target.value as ApPaymentMethod)}>
            {(["bank_transfer", "cash", "cheque", "cash_drawer"] as ApPaymentMethod[]).map((m) => (
              <option key={m} value={m}>
                {m === "cash_drawer" ? "إيداع في درج الوردية" : METHOD_LABELS[m]}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="المرجع">
          <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} />
        </Field>
      </div>
    </Modal>
  );
}

function OpeningModal({ supplierId, onClose, onDone }: { supplierId: string; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [amount, setAmount] = useState("");
  const [asOf, setAsOf] = useState(new Date().toISOString().slice(0, 10));
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());
  const submit = async () => {
    setBusy(true);
    const { error } = await supabase().rpc("set_supplier_opening_balance", {
      p_supplier: supplierId, p_amount: Number(amount), p_as_of: asOf, p_reason: reason, p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم تسجيل الرصيد الافتتاحي");
    onDone();
  };
  return (
    <Modal open onClose={onClose} title="الرصيد الافتتاحي (مرة واحدة)" size="sm" footer={<Button onClick={submit} loading={busy}>تسجيل</Button>}>
      <div className="space-y-3">
        <Field label="المبلغ (موجب = علينا، سالب = مقدّم لدى المورد)">
          <Input type="number" step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} />
        </Field>
        <Field label="بتاريخ">
          <Input type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        </Field>
        <Field label="السبب / المصدر">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="رصيد دفتري قبل النظام" />
        </Field>
        <p className="text-xs text-slate-500">لا يمكن تعديله أو تكراره بعد التسجيل.</p>
      </div>
    </Modal>
  );
}
