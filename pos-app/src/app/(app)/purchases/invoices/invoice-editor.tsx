"use client";

import { ArrowRight, CheckCircle2, Plus, Save, Trash2, XCircle } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { PurchaseAttachments } from "@/components/purchase-attachments";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, Checkbox, Field, Input, Loading, Modal, PageHeader, Select, Table, Textarea, useToast } from "@/components/ui";
import { errorMessage, money, round2, variantLabel } from "@/lib/format";
import { newRef } from "@/lib/inventory";
import {
  INVOICE_STATUS,
  MATCH_LABELS,
  METHOD_LABELS,
  TERMS_LABELS,
  type ApPaymentMethod,
  type ApPaymentTerms,
  type MatchLine,
  type SupplierInvoice,
} from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";
import type { Supplier } from "@/lib/types";

interface StockLine {
  receipt_item_id: string;
  grn_no: string;
  name: string;
  sku: string;
  available: number;     // غير مفوتر من سطر الاستلام
  po_cost: number;
  include: boolean;
  qty: string;
  unit_cost: string;
}

interface ExpenseLine {
  key: string;
  description: string;
  amount: string;
  vat: boolean;
}

interface GriRow {
  id: string;
  qty: number;
  qty_invoiced: number;
  qty_returned: number;
  unit_cost: number;
  receipt: { grn_no: string; purchase_order_id: string };
  variant: { sku: string; size: string | null; color: string | null; product: { name: string } };
}

const today = () => new Date().toISOString().slice(0, 10);

export function InvoiceEditor({ id, poId, supplierId }: { id: string | null; poId: string | null; supplierId: string | null }) {
  const toast = useToast();
  const router = useRouter();
  const { settings } = useSession();
  const [loading, setLoading] = useState(true);
  const [inv, setInv] = useState<SupplierInvoice | null>(null);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [supplier, setSupplier] = useState(supplierId ?? "");
  const [po, setPo] = useState<{ id: string; po_no: string; supplier_id: string } | null>(null);
  const [no, setNo] = useState("");
  const [date, setDate] = useState(today());
  const [due, setDue] = useState("");
  const [terms, setTerms] = useState<ApPaymentTerms>("credit");
  const [notes, setNotes] = useState("");
  const [stock, setStock] = useState<StockLine[]>([]);
  const [expenses, setExpenses] = useState<ExpenseLine[]>([]);
  const [match, setMatch] = useState<MatchLine[]>([]);
  const [busy, setBusy] = useState(false);
  const [posting, setPosting] = useState(false);
  const [voiding, setVoiding] = useState(false);
  const ref = useRef(newRef());

  const griToLine = (g: GriRow, selected?: { qty: number; unit_cost: number }): StockLine => ({
    receipt_item_id: g.id,
    grn_no: g.receipt.grn_no,
    name: `${g.variant.product.name} ${variantLabel(g.variant.size, g.variant.color)}`.trim(),
    sku: g.variant.sku,
    available: g.qty - g.qty_invoiced - g.qty_returned + (selected ? 0 : 0),
    po_cost: Number(g.unit_cost),
    include: selected ? true : !id,
    qty: String(selected ? selected.qty : g.qty - g.qty_invoiced - g.qty_returned),
    unit_cost: String(selected ? selected.unit_cost : g.unit_cost),
  });

  const loadGrLines = useCallback(async (purchaseOrder: string) => {
    const { data } = await supabase()
      .from("goods_receipt_items")
      .select("id, qty, qty_invoiced, qty_returned, unit_cost, receipt:goods_receipts!inner(grn_no, purchase_order_id), variant:product_variants(sku, size, color, product:products(name))")
      .eq("receipt.purchase_order_id", purchaseOrder)
      .order("id");
    return (data ?? []) as unknown as GriRow[];
  }, []);

  const loadMatch = useCallback(async (invoiceId: string) => {
    const { data } = await supabase().rpc("match_invoice", { p_id: invoiceId });
    setMatch(((data ?? []) as MatchLine[]).map((m) => ({ ...m, po_unit_cost: Number(m.po_unit_cost), invoice_unit_cost: Number(m.invoice_unit_cost), diff_pct: Number(m.diff_pct) })));
  }, []);

  const load = useCallback(async () => {
    const db = supabase();
    const { data: sups } = await db.from("suppliers").select("*").eq("is_active", true).order("name");
    setSuppliers((sups ?? []) as Supplier[]);
    try {
      if (id) {
        const { data: i, error } = await db.from("supplier_invoices").select("*").eq("id", id).single();
        if (error) throw error;
        const invoice = i as SupplierInvoice;
        setInv(invoice);
        setSupplier(invoice.supplier_id);
        setNo(invoice.supplier_invoice_no ?? "");
        setDate(invoice.invoice_date);
        setDue(invoice.due_date ?? "");
        setTerms(invoice.payment_terms);
        setNotes(invoice.notes ?? "");
        const { data: items } = await db.from("supplier_invoice_items").select("*").eq("invoice_id", id).order("id");
        const its = (items ?? []) as Array<{ receipt_item_id: string | null; description: string | null; qty: number; unit_cost: number; line_total: number; vat_amount: number }>;
        if (invoice.purchase_order_id) {
          const { data: p } = await db.from("purchase_orders").select("id, po_no, supplier_id").eq("id", invoice.purchase_order_id).single();
          setPo(p as typeof po);
          const gr = await loadGrLines(invoice.purchase_order_id);
          setStock(gr.map((g) => {
            const sel = its.find((x) => x.receipt_item_id === g.id);
            const line = griToLine(g, sel ? { qty: sel.qty, unit_cost: Number(sel.unit_cost) } : undefined);
            return invoice.status === "draft" ? line : { ...line, available: line.available + (sel?.qty ?? 0) };
          }).filter((l) => l.include || l.available > 0));
        } else if (its.some((x) => x.receipt_item_id)) {
          // فاتورة ربطت أسطر استلام بلا أمر شراء (شراء مباشر): عرض فقط
          setStock(its.filter((x) => x.receipt_item_id).map((x) => ({
            receipt_item_id: x.receipt_item_id!, grn_no: "", name: "", sku: "", available: x.qty, po_cost: Number(x.unit_cost),
            include: true, qty: String(x.qty), unit_cost: String(x.unit_cost),
          })));
        }
        setExpenses(its.filter((x) => !x.receipt_item_id).map((x) => ({
          key: newRef(), description: x.description ?? "", amount: String(x.line_total), vat: Number(x.vat_amount) > 0,
        })));
        if (its.some((x) => x.receipt_item_id)) await loadMatch(id);
      } else if (poId) {
        const { data: p } = await db.from("purchase_orders").select("id, po_no, supplier_id").eq("id", poId).single();
        const order = p as { id: string; po_no: string; supplier_id: string };
        setPo(order);
        setSupplier(order.supplier_id);
        const s = ((sups ?? []) as Supplier[]).find((x) => x.id === order.supplier_id);
        setTerms(s?.payment_terms_days ? "credit" : "cash");
        const gr = await loadGrLines(poId);
        setStock(gr.map((g) => griToLine(g)).filter((l) => l.available > 0));
      } else {
        setExpenses([{ key: newRef(), description: "", amount: "", vat: true }]);
      }
    } catch (e) {
      toast(errorMessage(e), "error");
    } finally {
      setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, poId, loadGrLines, loadMatch, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const sup = suppliers.find((s) => s.id === supplier);
  const vatRate = sup?.vat_registered === false ? 0 : Number(settings.vat_rate);
  const editable = !inv || inv.status === "draft";
  const totals = useMemo(() => {
    let sub = 0;
    let vat = 0;
    for (const l of stock) {
      if (!l.include) continue;
      const t = round2((Number(l.qty) || 0) * (Number(l.unit_cost) || 0));
      sub += t;
      vat += round2((t * vatRate) / 100);
    }
    for (const e of expenses) {
      const t = round2(Number(e.amount) || 0);
      sub += t;
      if (e.vat) vat += round2((t * vatRate) / 100);
    }
    return { sub: round2(sub), vat: round2(vat), total: round2(sub + vat) };
  }, [stock, expenses, vatRate]);

  const save = async (): Promise<string | null> => {
    if (!supplier) {
      toast("اختر المورد", "error");
      return null;
    }
    const lines = [
      ...stock.filter((l) => l.include && Number(l.qty) > 0).map((l) => ({ receipt_item_id: l.receipt_item_id, qty: Number(l.qty), unit_cost: Number(l.unit_cost) })),
      ...expenses.filter((e) => e.description.trim() && Number(e.amount) > 0).map((e) => ({ description: e.description.trim(), amount: Number(e.amount), vat: e.vat })),
    ];
    if (!lines.length) {
      toast("أضف بنود الفاتورة", "error");
      return null;
    }
    setBusy(true);
    const { data, error } = await supabase().rpc("save_supplier_invoice", {
      p_id: inv?.id ?? null,
      p_supplier: supplier,
      p_po: po?.id ?? null,
      p_supplier_invoice_no: no || null,
      p_invoice_date: date,
      p_due_date: due || null,
      p_payment_terms: terms,
      p_lines: lines,
      p_notes: notes || null,
      p_client_ref: inv ? null : ref.current,
    });
    setBusy(false);
    if (error) {
      toast(errorMessage(error), "error");
      return null;
    }
    return data as string;
  };

  const onSave = async () => {
    const newId = await save();
    if (!newId) return;
    toast("تم حفظ المسودة — راجع المطابقة ثم رحّل");
    if (!inv) router.replace(`/purchases/invoices/${newId}`);
    else load();
  };

  if (loading) return <Loading />;
  const st = inv ? INVOICE_STATUS[inv.status] : null;
  const blocking = match.some((m) => m.result === "qty_over_received");
  const needsOverride = match.some((m) => m.result === "price_over_tolerance");

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={inv ? `فاتورة مورد ${inv.doc_no}` : po ? `فاتورة للأمر ${po.po_no}` : "فاتورة مصروف"}
        subtitle={inv?.match_status ? `المطابقة: ${{ not_required: "غير مطلوبة", matched: "مطابقة", within_tolerance: "ضمن السماح", override: `تجاوز بسبب: ${inv.match_override_reason ?? ""}` }[inv.match_status]}` : undefined}
        actions={
          <>
            <Link href={po ? `/purchases/${po.id}` : "/purchases/invoices"}>
              <Button variant="ghost">
                <ArrowRight className="size-4" /> رجوع
              </Button>
            </Link>
            {st && <Badge tone={st.tone}>{st.label}</Badge>}
            {editable && (
              <Button variant="outline" onClick={onSave} loading={busy}>
                <Save className="size-4" /> حفظ مسودة
              </Button>
            )}
            {inv?.status === "draft" && (
              <Button onClick={() => setPosting(true)} disabled={blocking}>
                <CheckCircle2 className="size-4" /> ترحيل
              </Button>
            )}
            {inv && inv.status !== "void" && inv.kind !== "opening" && Number(inv.settled_amount) === 0 && (
              <Button variant="ghost" onClick={() => setVoiding(true)}>
                <XCircle className="size-4" /> إلغاء
              </Button>
            )}
          </>
        }
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="space-y-3 p-4">
          <Field label="المورد">
            <Select aria-label="المورد" value={supplier} disabled={!editable || !!po} onChange={(e) => setSupplier(e.target.value)}>
              <option value="">اختر</option>
              {suppliers.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="رقم فاتورة المورد">
            <Input dir="ltr" aria-label="رقم فاتورة المورد" value={no} disabled={!editable} onChange={(e) => setNo(e.target.value)} />
          </Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="التاريخ">
              <Input type="date" value={date} disabled={!editable} onChange={(e) => setDate(e.target.value)} />
            </Field>
            <Field label="الاستحقاق">
              <Input type="date" value={due} disabled={!editable} onChange={(e) => setDue(e.target.value)} placeholder="حسب مدة السداد" />
            </Field>
          </div>
          <Field label="طريقة السداد">
            <Select aria-label="طريقة السداد" value={terms} disabled={!editable} onChange={(e) => setTerms(e.target.value as ApPaymentTerms)}>
              {(Object.keys(TERMS_LABELS) as ApPaymentTerms[]).map((t) => (
                <option key={t} value={t}>
                  {TERMS_LABELS[t]}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="ملاحظات">
            <Textarea rows={2} value={notes} disabled={!editable} onChange={(e) => setNotes(e.target.value)} />
          </Field>
          <div className="space-y-1 border-t border-slate-100 pt-3 text-sm">
            <div className="flex justify-between"><span className="text-slate-600">قبل الضريبة</span><span>{money(inv && !editable ? inv.subtotal : totals.sub)}</span></div>
            <div className="flex justify-between"><span className="text-slate-600">ضريبة المدخلات {vatRate}%</span><span>{money(inv && !editable ? inv.vat_amount : totals.vat)}</span></div>
            <div className="flex justify-between text-base font-bold"><span>الإجمالي</span><span>{money(inv && !editable ? inv.total : totals.total)}</span></div>
            {inv && inv.status !== "draft" && (
              <div className="flex justify-between text-slate-600"><span>المسدَّد</span><span>{money(inv.settled_amount)}</span></div>
            )}
          </div>
        </Card>

        <div className="space-y-4 lg:col-span-2">
          {stock.length > 0 && (
            <Card>
              <div className="border-b border-slate-100 p-3">
                <h3 className="font-semibold text-slate-900">البضاعة المستلمة (المطابقة الثلاثية)</h3>
                <p className="text-xs text-slate-500">
                  السماح في فرق السعر {Number(settings.purchase_match_tolerance_pct ?? 2)}%. لا تُفوتر كمية أكثر من المستلم غير المفوتر.
                </p>
              </div>
              <Table>
                <thead>
                  <tr>
                    <th></th>
                    <th>الصنف</th>
                    <th>متاح للفوترة</th>
                    <th>الكمية</th>
                    <th>سعر أمر الشراء</th>
                    <th>سعر الفاتورة</th>
                    <th>المطابقة</th>
                  </tr>
                </thead>
                <tbody>
                  {stock.map((l, i) => {
                    const m = match.find((x) => x.receipt_item_id === l.receipt_item_id);
                    const diff = l.po_cost > 0 ? ((Number(l.unit_cost) - l.po_cost) / l.po_cost) * 100 : 0;
                    return (
                      <tr key={l.receipt_item_id}>
                        <td>
                          {editable && (
                            <input type="checkbox" aria-label={`تضمين ${l.sku}`} className="size-4 accent-brand-700" checked={l.include}
                              onChange={(e) => setStock((ss) => ss.map((x, j) => (j === i ? { ...x, include: e.target.checked } : x)))} />
                          )}
                        </td>
                        <td>
                          <p className="font-medium">{l.name}</p>
                          <p className="text-xs text-slate-500"><span className="ltr-nums">{l.sku}</span> · <span className="ltr-nums">{l.grn_no}</span></p>
                        </td>
                        <td>{l.available}</td>
                        <td>
                          {editable ? (
                            <Input type="number" min={1} max={l.available} aria-label={`كمية ${l.sku}`} className="h-9 w-20" value={l.qty}
                              onChange={(e) => setStock((ss) => ss.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} />
                          ) : l.qty}
                        </td>
                        <td>{money(l.po_cost)}</td>
                        <td>
                          {editable ? (
                            <Input type="number" step="0.01" min={0} aria-label={`سعر ${l.sku}`} className="h-9 w-24" value={l.unit_cost}
                              onChange={(e) => setStock((ss) => ss.map((x, j) => (j === i ? { ...x, unit_cost: e.target.value } : x)))} />
                          ) : money(l.unit_cost)}
                          {Math.abs(diff) > 0.001 && <span className={`block text-xs ${Math.abs(diff) > Number(settings.purchase_match_tolerance_pct ?? 2) ? "text-red-600" : "text-amber-700"}`}>{diff > 0 ? "+" : ""}{diff.toFixed(1)}%</span>}
                        </td>
                        <td>{m ? <Badge tone={MATCH_LABELS[m.result].tone}>{MATCH_LABELS[m.result].label}</Badge> : <span className="text-xs text-slate-400">احفظ للمطابقة</span>}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </Table>
            </Card>
          )}

          {(expenses.length > 0 || (editable && !po)) && (
            <Card>
              <div className="flex items-center justify-between border-b border-slate-100 p-3">
                <h3 className="font-semibold text-slate-900">بنود مصروف (خدمة، شحن…)</h3>
                {editable && (
                  <Button size="sm" variant="outline" onClick={() => setExpenses((e) => [...e, { key: newRef(), description: "", amount: "", vat: true }])}>
                    <Plus className="size-4" /> بند
                  </Button>
                )}
              </div>
              <ul className="divide-y divide-slate-100">
                {expenses.map((e, i) => (
                  <li key={e.key} className="flex flex-wrap items-center gap-2 p-3">
                    <Input className="min-w-40 flex-1" placeholder="الوصف" aria-label="وصف البند" value={e.description} disabled={!editable}
                      onChange={(ev) => setExpenses((xs) => xs.map((x, j) => (j === i ? { ...x, description: ev.target.value } : x)))} />
                    <Input className="w-28" type="number" step="0.01" placeholder="المبلغ" aria-label="مبلغ البند" value={e.amount} disabled={!editable}
                      onChange={(ev) => setExpenses((xs) => xs.map((x, j) => (j === i ? { ...x, amount: ev.target.value } : x)))} />
                    <Checkbox label="عليه ضريبة" checked={e.vat} onChange={(v) => editable && setExpenses((xs) => xs.map((x, j) => (j === i ? { ...x, vat: v } : x)))} />
                    {editable && (
                      <Button size="sm" variant="ghost" aria-label="حذف" onClick={() => setExpenses((xs) => xs.filter((_, j) => j !== i))}>
                        <Trash2 className="size-4" />
                      </Button>
                    )}
                  </li>
                ))}
              </ul>
            </Card>
          )}

          {inv && <PurchaseAttachments ownerType="supplier_invoice" ownerId={inv.id} />}
        </div>
      </div>

      {posting && inv && (
        <PostModal invoice={inv} total={totals.total} needsOverride={needsOverride} match={match}
          onClose={() => setPosting(false)}
          onDone={() => { setPosting(false); toast("تم ترحيل الفاتورة إلى حساب المورد"); load(); }} />
      )}
      {voiding && inv && (
        <VoidModal invoiceId={inv.id} onClose={() => setVoiding(false)} onDone={() => { setVoiding(false); toast("أُلغيت الفاتورة بقيد عكسي"); load(); }} />
      )}
    </div>
  );
}

function PostModal({ invoice, total, needsOverride, match, onClose, onDone }: {
  invoice: SupplierInvoice; total: number; needsOverride: boolean; match: MatchLine[]; onClose: () => void; onDone: () => void;
}) {
  const toast = useToast();
  const [reason, setReason] = useState("");
  const [method, setMethod] = useState<ApPaymentMethod>("bank_transfer");
  const [reference, setReference] = useState("");
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const pays = invoice.payment_terms !== "credit";
  const submit = async () => {
    if (needsOverride && !reason.trim()) return toast("اكتب سبب تجاوز فرق السعر", "error");
    setBusy(true);
    const { error } = await supabase().rpc("post_supplier_invoice", {
      p_id: invoice.id,
      p_override_reason: needsOverride ? reason.trim() : null,
      p_payment: pays ? { method, reference: reference || null, amount: invoice.payment_terms === "partial" ? Number(amount) : null } : null,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    onDone();
  };
  return (
    <Modal open onClose={onClose} title="ترحيل فاتورة المورد" size="md" footer={<Button onClick={submit} loading={busy}>ترحيل</Button>}>
      <div className="space-y-3 text-sm">
        <p>
          سيُسجَّل {money(invoice.total || total)} ديناً على حساب المورد
          {invoice.payment_terms === "cash" ? " ويُسدَّد كاملاً الآن" : invoice.payment_terms === "partial" ? " مع دفعة جزئية الآن" : " حتى تاريخ الاستحقاق"}.
          فرق السعر عن أمر الشراء يعدّل متوسط التكلفة للكمية الموجودة، ونصيب ما بيع قبل الفاتورة يُسجَّل فرق تكلفة.
        </p>
        {needsOverride && (
          <>
            <ul className="rounded-lg bg-red-50 p-2 text-xs text-red-800">
              {match.filter((m) => m.result === "price_over_tolerance").map((m) => (
                <li key={m.line_id}>
                  {m.sku}: {money(m.invoice_unit_cost)} مقابل {money(m.po_unit_cost)} ({m.diff_pct}%)
                </li>
              ))}
            </ul>
            <Field label="سبب تجاوز فرق السعر (إلزامي)">
              <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
            </Field>
          </>
        )}
        {pays && (
          <div className="grid gap-3 sm:grid-cols-2">
            {invoice.payment_terms === "partial" && (
              <Field label="الدفعة الآن">
                <Input type="number" step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} />
              </Field>
            )}
            <Field label="طريقة الدفع">
              <Select value={method} onChange={(e) => setMethod(e.target.value as ApPaymentMethod)}>
                {(["bank_transfer", "cash", "cheque", "card", "cash_drawer"] as ApPaymentMethod[]).map((m) => (
                  <option key={m} value={m}>
                    {METHOD_LABELS[m]}
                  </option>
                ))}
              </Select>
            </Field>
            {(method === "bank_transfer" || method === "cheque") && (
              <Field label="المرجع">
                <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} />
              </Field>
            )}
          </div>
        )}
      </div>
    </Modal>
  );
}

function VoidModal({ invoiceId, onClose, onDone }: { invoiceId: string; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <Modal open onClose={onClose} title="إلغاء الفاتورة" size="sm"
      footer={
        <Button variant="danger" disabled={!reason.trim()} loading={busy}
          onClick={async () => {
            setBusy(true);
            const { error } = await supabase().rpc("void_supplier_invoice", { p_id: invoiceId, p_reason: reason.trim() });
            setBusy(false);
            if (error) return toast(errorMessage(error), "error");
            onDone();
          }}>
          إلغاء الفاتورة
        </Button>
      }>
      <Field label="السبب (إلزامي)">
        <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
      <p className="mt-2 text-xs text-slate-500">يُعكس القيد وتعديل التكلفة، وتعود الكميات «غير مفوترة». لا يُلغى ما عليه سداد.</p>
    </Modal>
  );
}
