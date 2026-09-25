"use client";

import { Printer } from "lucide-react";
import { useEffect, useState } from "react";
import { dateTime, errorMessage, money } from "@/lib/format";
import { printNow } from "@/lib/sales";
import { supabase } from "@/lib/supabase/client";
import type { OpenShift, ShiftSummary } from "@/lib/types";
import { PrintPortal } from "./print-portal";
import { useSession } from "./session-context";
import { Badge, Button, Field, Input, Loading, Modal, Textarea, cn, useToast } from "./ui";

/** The signed-in user's open shift, or null. */
export async function fetchMyOpenShift(userId: string): Promise<OpenShift | null> {
  const { data } = await supabase()
    .from("shifts")
    .select("id, shift_no, opened_at, opening_cash")
    .eq("cashier_id", userId)
    .eq("status", "open")
    .maybeSingle();
  return (data as OpenShift | null) ?? null;
}

export function OpenShiftModal({ open, onClose, onOpened }: { open: boolean; onClose: () => void; onOpened: () => void }) {
  const toast = useToast();
  const [cash, setCash] = useState("");
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    if (cash === "" || Number(cash) < 0) return toast("أدخل الرصيد الافتتاحي في الدرج (0 إن كان فارغاً)", "error");
    setBusy(true);
    const { error } = await supabase().rpc("open_shift", { p_opening_cash: Number(cash), p_notes: notes || null });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم فتح الوردية");
    setCash("");
    setNotes("");
    onOpened();
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="فتح وردية"
      size="sm"
      footer={
        <Button onClick={submit} loading={busy} className="w-full" size="lg">
          فتح الوردية
        </Button>
      }
    >
      <div className="space-y-3">
        <Field label="الرصيد الافتتاحي في الدرج (ر.س)" hint="النقد الموجود في الدرج الآن قبل أول عملية بيع">
          <Input type="number" inputMode="decimal" min={0} step="0.01" autoFocus value={cash} onChange={(e) => setCash(e.target.value)} placeholder="0.00" />
        </Field>
        <Field label="ملاحظة (اختياري)">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
      </div>
    </Modal>
  );
}

export function CashMovementModal({
  type,
  onClose,
  onDone,
}: {
  type: "in" | "out" | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const { isManager } = useSession();
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    if (!type) return;
    if (!(Number(amount) > 0)) return toast("أدخل المبلغ", "error");
    if (!reason.trim()) return toast("السبب مطلوب", "error");
    setBusy(true);
    const { error } = await supabase().rpc("add_cash_movement", { p_type: type, p_amount: Number(amount), p_reason: reason });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast(type === "in" ? "تم تسجيل الإيداع" : "تم تسجيل السحب");
    setAmount("");
    setReason("");
    onDone();
  };

  return (
    <Modal
      open={type !== null}
      onClose={onClose}
      title={type === "in" ? "إيداع نقدي في الدرج" : "سحب نقدي من الدرج"}
      size="sm"
      footer={
        <Button onClick={submit} loading={busy} variant={type === "out" ? "danger" : "primary"}>
          تسجيل
        </Button>
      }
    >
      <div className="space-y-3">
        <Field label="المبلغ (ر.س)">
          <Input type="number" inputMode="decimal" min={0} step="0.01" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} />
        </Field>
        <Field label="السبب">
          <Input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder={type === "in" ? "فكة من الإدارة" : "شراء أكياس / مصروف"}
          />
        </Field>
        {type === "out" && isManager && (
          <p className="rounded-lg bg-slate-50 p-2.5 text-xs text-slate-600">
            لمصروف يُحتسب في صافي الربح (إيجار، كهرباء، مستلزمات) سجّله من صفحة «المصروفات» باختيار «من درج الوردية» — يُخصم من الدرج تلقائياً.
          </p>
        )}
      </div>
    </Modal>
  );
}

/** Blind count: the counted cash is entered before any expected figure is shown. */
export function CloseShiftModal({
  shift,
  onClose,
  onClosed,
}: {
  shift: { id: string; shift_no: string; cashier_name?: string | null } | null;
  onClose: () => void;
  onClosed: (summary: ShiftSummary) => void;
}) {
  const toast = useToast();
  const [counted, setCounted] = useState("");
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    if (!shift) return;
    if (counted === "" || Number(counted) < 0) return toast("أدخل النقد المعدود في الدرج", "error");
    setBusy(true);
    const { data, error } = await supabase().rpc("close_shift", {
      p_shift_id: shift.id,
      p_counted_cash: Number(counted),
      p_notes: notes || null,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    setCounted("");
    setNotes("");
    onClosed(data as ShiftSummary);
  };

  return (
    <Modal
      open={shift !== null}
      onClose={onClose}
      title={`إغلاق الوردية ${shift?.shift_no ?? ""}`}
      size="sm"
      footer={
        <Button onClick={submit} loading={busy} className="w-full" size="lg">
          إغلاق الوردية
        </Button>
      }
    >
      <div className="space-y-3">
        {shift?.cashier_name && <p className="text-sm text-slate-600">الموظف: {shift.cashier_name}</p>}
        <Field label="النقد المعدود في الدرج (ر.س)" hint="عُدّ كل النقد الموجود في الدرج بما فيه الرصيد الافتتاحي">
          <Input type="number" inputMode="decimal" min={0} step="0.01" autoFocus value={counted} onChange={(e) => setCounted(e.target.value)} placeholder="0.00" />
        </Field>
        <Field label="ملاحظة (اختياري)">
          <Textarea className="min-h-16" value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
        <p className="rounded-lg bg-amber-50 p-2.5 text-xs text-amber-800">لا يمكن التراجع عن الإغلاق. ستظهر المطابقة والفرق بعد الإغلاق.</p>
      </div>
    </Modal>
  );
}

function differenceTone(diff: number): "green" | "red" | "amber" {
  if (Math.abs(diff) < 0.005) return "green";
  return diff < 0 ? "red" : "amber";
}

export function differenceLabel(diff: number | null | undefined): { text: string; tone: "green" | "red" | "amber" | "slate" } {
  if (diff === null || diff === undefined) return { text: "-", tone: "slate" };
  const d = Number(diff);
  if (Math.abs(d) < 0.005) return { text: "مطابق", tone: "green" };
  return { text: d < 0 ? `عجز ${money(Math.abs(d))}` : `زيادة ${money(d)}`, tone: differenceTone(d) };
}

/** Thermal Z-report (80mm), used on screen and for printing. */
export function ShiftReport({ s, storeName }: { s: ShiftSummary; storeName: string }) {
  const n = s.numbers;
  const full = n.expected_cash !== undefined;
  const row = (label: string, value: number | undefined, bold = false) =>
    value === undefined ? null : (
      <tr style={bold ? { fontWeight: 700 } : undefined}>
        <td>{label}</td>
        <td style={{ textAlign: "left" }}>{Number(value).toFixed(2)}</td>
      </tr>
    );
  return (
    <div className="receipt" dir="rtl">
      <div style={{ textAlign: "center" }}>
        <div style={{ fontSize: "1.3em", fontWeight: 700 }}>{storeName}</div>
        <div style={{ fontWeight: 700 }}>{s.status === "closed" ? "تقرير إغلاق الوردية" : "ملخص الوردية (مفتوحة)"}</div>
      </div>
      <div className="dashed" />
      <table>
        <tbody>
          <tr>
            <td>رقم الوردية</td>
            <td style={{ textAlign: "left" }}>{s.shift_no}</td>
          </tr>
          <tr>
            <td>الموظف</td>
            <td style={{ textAlign: "left" }}>{s.cashier_name}</td>
          </tr>
          <tr>
            <td>الفتح</td>
            <td style={{ textAlign: "left" }} className="ltr-nums">
              {dateTime(s.opened_at)}
            </td>
          </tr>
          {s.closed_at && (
            <tr>
              <td>الإغلاق</td>
              <td style={{ textAlign: "left" }} className="ltr-nums">
                {dateTime(s.closed_at)}
              </td>
            </tr>
          )}
          {s.closed_by_name && s.closed_by_name !== s.cashier_name && (
            <tr>
              <td>أغلقها</td>
              <td style={{ textAlign: "left" }}>{s.closed_by_name}</td>
            </tr>
          )}
        </tbody>
      </table>
      <div className="dashed" />
      <table>
        <tbody>
          <tr>
            <td>عدد الفواتير</td>
            <td style={{ textAlign: "left" }}>{n.sales_count}</td>
          </tr>
          {row("إجمالي المبيعات", n.total_sales, true)}
          {row("نقدي (صافي بعد الباقي)", n.cash_sales)}
          {row("شبكة", n.card_sales)}
          {row("تحويل", n.transfer_sales)}
          {row("رصيد استبدال", n.exchange_credit)}
          <tr>
            <td>عدد المرتجعات</td>
            <td style={{ textAlign: "left" }}>{n.returns_count}</td>
          </tr>
          {row("مرتجع نقدي", n.cash_refunds)}
          {row("مرتجع شبكة", n.card_refunds)}
          {row("مرتجع تحويل", n.transfer_refunds)}
        </tbody>
      </table>
      {full && (
        <>
          <div className="dashed" />
          <div style={{ fontWeight: 700 }}>مطابقة الدرج</div>
          <table>
            <tbody>
              {row("الرصيد الافتتاحي", n.opening_cash)}
              {row("+ مبيعات نقدية", n.cash_sales)}
              {row("− مرتجعات نقدية", n.cash_refunds)}
              {row("+ إيداعات", n.cash_in)}
              {row("− سحوبات", n.cash_out)}
              {row("النقد المتوقع", n.expected_cash, true)}
              {s.counted_cash !== null && row("النقد المعدود", s.counted_cash, true)}
            </tbody>
          </table>
          {s.cash_difference !== null && (
            <div style={{ textAlign: "center", fontWeight: 700, fontSize: "1.15em", marginTop: 4 }}>
              {differenceLabel(s.cash_difference).text}
            </div>
          )}
        </>
      )}
      {s.movements.length > 0 && (
        <>
          <div className="dashed" />
          <div style={{ fontWeight: 700 }}>حركات الدرج</div>
          <table>
            <tbody>
              {s.movements.map((m, i) => (
                <tr key={i}>
                  <td>
                    {m.type === "in" ? "إيداع" : "سحب"} — {m.reason}
                  </td>
                  <td style={{ textAlign: "left" }}>{Number(m.amount).toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
      {s.closing_notes && (
        <>
          <div className="dashed" />
          <div>ملاحظة: {s.closing_notes}</div>
        </>
      )}
      <div className="dashed" />
      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 16 }}>
        <span>توقيع الموظف: ________</span>
        <span>المدير: ________</span>
      </div>
    </div>
  );
}

export function ShiftReportModal({
  shiftId,
  onClose,
  onRequestClose,
}: {
  shiftId: string | null;
  onClose: () => void;
  onRequestClose?: (s: ShiftSummary) => void;
}) {
  const toast = useToast();
  const { settings, isManager } = useSession();
  const [data, setData] = useState<ShiftSummary | null>(null);

  useEffect(() => {
    if (!shiftId) return;
    let cancelled = false;
    supabase()
      .rpc("shift_summary", { p_shift_id: shiftId })
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) toast(errorMessage(error), "error");
        else setData(data as ShiftSummary);
      });
    return () => {
      cancelled = true;
      setData(null);
    };
  }, [shiftId, toast]);

  if (!shiftId) return null;
  return (
    <>
      <Modal
        open
        onClose={onClose}
        title={data ? `الوردية ${data.shift_no}` : "الوردية"}
        footer={
          data && (
            <>
              {data.status === "open" && isManager && onRequestClose && (
                <Button variant="secondary" onClick={() => onRequestClose(data)}>
                  إغلاق هذه الوردية
                </Button>
              )}
              <Button onClick={printNow}>
                <Printer className="size-4" /> طباعة
              </Button>
            </>
          )
        }
      >
        {!data ? (
          <Loading />
        ) : (
          <div className="space-y-3">
            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={data.status === "open" ? "blue" : "slate"}>{data.status === "open" ? "مفتوحة" : "مغلقة"}</Badge>
              {data.cash_difference !== null && (
                <Badge tone={differenceLabel(data.cash_difference).tone}>{differenceLabel(data.cash_difference).text}</Badge>
              )}
            </div>
            <div className={cn("flex justify-center rounded-lg bg-slate-100 p-3")}>
              <div className="shadow">
                <ShiftReport s={data} storeName={settings.store_name} />
              </div>
            </div>
          </div>
        )}
      </Modal>
      {data && (
        <PrintPortal>
          <ShiftReport s={data} storeName={settings.store_name} />
        </PrintPortal>
      )}
    </>
  );
}
