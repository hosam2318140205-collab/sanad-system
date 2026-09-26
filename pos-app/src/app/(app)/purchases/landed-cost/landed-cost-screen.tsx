"use client";

import { Plus, Ship, Trash2 } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Table, Textarea, useToast } from "@/components/ui";
import { dateTime, errorMessage, money } from "@/lib/format";
import { newRef } from "@/lib/inventory";
import { COST_TYPE_LABELS } from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";
import type { Supplier } from "@/lib/types";

interface Voucher {
  id: string;
  lc_no: string;
  status: string;
  method: string;
  total_amount: number;
  notes: string | null;
  created_at: string;
  lines: Array<{ cost_type: string; amount: number; supplier: { name: string } | null }>;
}

interface Receipt {
  id: string;
  grn_no: string;
  received_at: string;
  supplier: { name: string } | null;
  po: { po_no: string } | null;
}

interface Preview {
  receipt_item_id: string;
  sku: string;
  qty: number;
  basis: number;
  amount: number;
  per_unit: number;
}

interface CostLine {
  key: string;
  cost_type: string;
  supplier_id: string;
  supplier_invoice_no: string;
  description: string;
  amount: string;
}

const METHODS: Record<string, string> = { value: "بقيمة البضاعة", qty: "بعدد القطع", manual: "يدوي" };

export function LandedCostScreen() {
  const toast = useToast();
  const [rows, setRows] = useState<Voucher[] | null>(null);
  const [creating, setCreating] = useState(false);
  const [voiding, setVoiding] = useState<Voucher | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase()
      .from("landed_cost_vouchers")
      .select("*, lines:landed_cost_lines(cost_type, amount, supplier:suppliers(name))")
      .order("created_at", { ascending: false })
      .limit(100);
    if (error) toast(errorMessage(error), "error");
    setRows((data ?? []) as Voucher[]);
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="تكاليف الوصول"
        subtitle="الشحن والجمارك والنقل تُضاف إلى تكلفة البضاعة المستلمة (بلا ضريبة)، وتُسجَّل ديناً على شركة الشحن أو الجمارك"
        actions={
          <Button onClick={() => setCreating(true)}>
            <Plus className="size-4" /> سند تكاليف
          </Button>
        }
      />
      <Card>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد سندات تكاليف وصول" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>السند</th>
                <th>البنود</th>
                <th>التوزيع</th>
                <th>الإجمالي</th>
                <th>التاريخ</th>
                <th>الحالة</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((v) => (
                <tr key={v.id}>
                  <td className="ltr-nums font-medium">{v.lc_no}</td>
                  <td className="text-sm">
                    {v.lines.map((l, i) => (
                      <span key={i} className="block">
                        {COST_TYPE_LABELS[l.cost_type]} — {l.supplier?.name}: {money(l.amount)}
                      </span>
                    ))}
                  </td>
                  <td>{METHODS[v.method]}</td>
                  <td className="font-semibold">{money(v.total_amount)}</td>
                  <td className="ltr-nums text-xs">{dateTime(v.created_at)}</td>
                  <td>{v.status === "void" ? <Badge tone="red">ملغى</Badge> : <Badge tone="green">مرحّل</Badge>}</td>
                  <td>
                    {v.status === "posted" && (
                      <Button size="sm" variant="ghost" onClick={() => setVoiding(v)}>
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
      {creating && <NewVoucher onClose={() => setCreating(false)} onDone={() => (setCreating(false), load())} />}
      {voiding && <VoidVoucher voucher={voiding} onClose={() => setVoiding(null)} onDone={() => (setVoiding(null), load())} />}
    </div>
  );
}

function NewVoucher({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [receipts, setReceipts] = useState<Receipt[]>([]);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [method, setMethod] = useState("value");
  const [lines, setLines] = useState<CostLine[]>([{ key: newRef(), cost_type: "freight", supplier_id: "", supplier_invoice_no: "", description: "", amount: "" }]);
  const [manual, setManual] = useState<Record<string, string>>({});
  const [preview, setPreview] = useState<Preview[]>([]);
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());

  useEffect(() => {
    const db = supabase();
    db.from("goods_receipts").select("id, grn_no, received_at, supplier:suppliers(name), po:purchase_orders(po_no)")
      .eq("is_historical", false).order("received_at", { ascending: false }).limit(60)
      .then(({ data }) => setReceipts((data ?? []) as unknown as Receipt[]));
    db.from("suppliers").select("*").eq("is_active", true).order("name").then(({ data }) => setSuppliers((data ?? []) as Supplier[]));
  }, []);

  const total = lines.reduce((a, l) => a + (Number(l.amount) || 0), 0);

  useEffect(() => {
    const t = setTimeout(async () => {
      if (!selected.length || total <= 0) return setPreview([]);
      const { data, error } = await supabase().rpc("landed_cost_preview", {
        p_receipts: selected,
        p_total: method === "manual" ? Object.values(manual).reduce((a, v) => a + (Number(v) || 0), 0) : total,
        p_method: method,
        p_manual: method === "manual" ? Object.entries(manual).map(([receipt_item_id, amount]) => ({ receipt_item_id, amount: Number(amount) || 0 })) : null,
      });
      if (!error) setPreview(((data ?? []) as Preview[]).map((p) => ({ ...p, amount: Number(p.amount), per_unit: Number(p.per_unit), basis: Number(p.basis) })));
    }, 250);
    return () => clearTimeout(t);
  }, [selected, method, total, manual]);

  const submit = async () => {
    if (!selected.length) return toast("اختر سند استلام واحداً على الأقل", "error");
    if (lines.some((l) => !l.supplier_id || !(Number(l.amount) > 0))) return toast("كل بند يحتاج مورداً ومبلغاً", "error");
    setBusy(true);
    const { error } = await supabase().rpc("post_landed_cost", {
      p_receipts: selected,
      p_lines: lines.map((l) => ({
        cost_type: l.cost_type, supplier_id: l.supplier_id, amount: Number(l.amount),
        supplier_invoice_no: l.supplier_invoice_no || null, description: l.description || null,
      })),
      p_method: method,
      p_manual: method === "manual" ? Object.entries(manual).map(([receipt_item_id, amount]) => ({ receipt_item_id, amount: Number(amount) || 0 })) : null,
      p_notes: notes || null,
      p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم ترحيل التكاليف وتعديل التكلفة");
    onDone();
  };

  return (
    <Modal open onClose={onClose} title="سند تكاليف وصول" size="xl" footer={<Button onClick={submit} loading={busy}><Ship className="size-4" /> ترحيل</Button>}>
      <div className="space-y-4">
        <Field label="سندات الاستلام (الشحنة)">
          <div className="max-h-40 space-y-1 overflow-y-auto rounded-lg border border-slate-200 p-2">
            {receipts.length === 0 && <p className="text-sm text-slate-500">لا توجد سندات استلام.</p>}
            {receipts.map((r) => (
              <label key={r.id} className="flex items-center gap-2 text-sm">
                <input type="checkbox" className="size-4 accent-brand-700" checked={selected.includes(r.id)}
                  onChange={(e) => setSelected((s) => (e.target.checked ? [...s, r.id] : s.filter((x) => x !== r.id)))} />
                <span className="ltr-nums font-medium">{r.grn_no}</span>
                <span className="text-slate-500">{r.supplier?.name} · {r.po?.po_no} · {dateTime(r.received_at)}</span>
              </label>
            ))}
          </div>
        </Field>
        <div>
          <div className="mb-2 flex items-center justify-between">
            <span className="text-sm font-medium text-slate-700">البنود</span>
            <Button size="sm" variant="outline"
              onClick={() => setLines((l) => [...l, { key: newRef(), cost_type: "customs", supplier_id: "", supplier_invoice_no: "", description: "", amount: "" }])}>
              <Plus className="size-4" /> بند
            </Button>
          </div>
          <ul className="space-y-2">
            {lines.map((l, i) => (
              <li key={l.key} className="grid grid-cols-2 gap-2 rounded-lg border border-slate-200 p-2 sm:grid-cols-5">
                <Select aria-label="نوع التكلفة" value={l.cost_type} onChange={(e) => setLines((xs) => xs.map((x, j) => (j === i ? { ...x, cost_type: e.target.value } : x)))}>
                  {Object.entries(COST_TYPE_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </Select>
                <Select aria-label="مورد التكلفة" value={l.supplier_id} onChange={(e) => setLines((xs) => xs.map((x, j) => (j === i ? { ...x, supplier_id: e.target.value } : x)))}>
                  <option value="">المورد (شركة الشحن…)</option>
                  {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </Select>
                <Input dir="ltr" placeholder="رقم فاتورته" aria-label="رقم فاتورة التكلفة" value={l.supplier_invoice_no}
                  onChange={(e) => setLines((xs) => xs.map((x, j) => (j === i ? { ...x, supplier_invoice_no: e.target.value } : x)))} />
                <Input type="number" step="0.01" placeholder="المبلغ قبل الضريبة" aria-label="مبلغ التكلفة" value={l.amount}
                  onChange={(e) => setLines((xs) => xs.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} />
                <Button variant="ghost" aria-label="حذف البند" disabled={lines.length === 1} onClick={() => setLines((xs) => xs.filter((_, j) => j !== i))}>
                  <Trash2 className="size-4" />
                </Button>
              </li>
            ))}
          </ul>
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="طريقة التوزيع">
            <Select value={method} onChange={(e) => setMethod(e.target.value)}>
              {Object.entries(METHODS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </Select>
          </Field>
          <Field label="ملاحظات">
            <Textarea rows={1} value={notes} onChange={(e) => setNotes(e.target.value)} />
          </Field>
        </div>
        {preview.length > 0 && (
          <Table>
            <thead>
              <tr><th>الصنف</th><th>الكمية</th><th>الأساس</th><th>النصيب</th><th>للقطعة</th></tr>
            </thead>
            <tbody>
              {preview.map((p) => (
                <tr key={p.receipt_item_id}>
                  <td className="ltr-nums">{p.sku}</td>
                  <td>{p.qty}</td>
                  <td>{method === "manual" ? (
                    <Input type="number" step="0.01" className="h-8 w-24" aria-label={`توزيع ${p.sku}`} value={manual[p.receipt_item_id] ?? ""}
                      onChange={(e) => setManual((m) => ({ ...m, [p.receipt_item_id]: e.target.value }))} />
                  ) : method === "value" ? money(p.basis) : p.basis}</td>
                  <td className="font-semibold">{money(p.amount)}</td>
                  <td>{p.per_unit.toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
        <p className="text-xs text-slate-500">
          الإجمالي {money(total)}. المجموع يطابق حرفياً (آخر سطر يأخذ فرق التقريب). الضريبة تُحسب على فاتورة كل مورد تكلفة ولا تدخل تكلفة الصنف.
          نصيب ما بيع قبل الترحيل يُسجَّل فرق تكلفة.
        </p>
      </div>
    </Modal>
  );
}

function VoidVoucher({ voucher, onClose, onDone }: { voucher: Voucher; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <Modal open onClose={onClose} title={`إلغاء ${voucher.lc_no}`} size="sm"
      footer={
        <Button variant="danger" disabled={!reason.trim()} loading={busy}
          onClick={async () => {
            setBusy(true);
            const { error } = await supabase().rpc("void_landed_cost", { p_id: voucher.id, p_reason: reason.trim() });
            setBusy(false);
            if (error) return toast(errorMessage(error), "error");
            toast("أُلغي السند وعُكست التكلفة وفواتير المصروف");
            onDone();
          }}>
          إلغاء السند
        </Button>
      }>
      <Field label="السبب (إلزامي)">
        <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
    </Modal>
  );
}
