"use client";

import { Printer, Repeat, Search, Undo2 } from "lucide-react";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { CameraScanButton, CameraScanner } from "@/components/camera-scanner";
import { PrintPortal } from "@/components/print-portal";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, EmptyState, Field, Input, Modal, PageHeader, Select, Table, Textarea, cn, useToast } from "@/components/ui";
import { REFUND_LABELS, dateTime, errorMessage, money, round2 } from "@/lib/format";
import { printNow } from "@/lib/sales";
import { supabase } from "@/lib/supabase/client";
import type { RefundMethod, ReturnRecord } from "@/lib/types";

interface ReturnableItem {
  id: string;
  variant_id: string;
  product_name: string;
  variant_label: string | null;
  sku: string | null;
  qty: number;
  returned_qty: number;
  unit_price: number;
  line_total: number;
  vat_amount: number;
}

interface ReturnableSale {
  id: string;
  invoice_no: string;
  created_at: string;
  total: number;
  returned_amount: number;
  status: string;
  customer_name: string | null;
  days_since: number;
  return_days: number;
  items: ReturnableItem[];
}

type RecentReturn = ReturnRecord & { sale: { invoice_no: string } | null };

interface ReturnContext {
  customer_id: string | null;
  customer_phone: string | null;
  on_account: number;
  max_direct_refund: number | null;
  loyalty_points_earned: number;
  loyalty_points_redeemed: number;
}

export function ReturnsScreen() {
  const toast = useToast();
  const router = useRouter();
  const params = useSearchParams();
  const { settings, profile } = useSession();
  const [invoice, setInvoice] = useState(params.get("invoice") ?? "");
  const [sale, setSale] = useState<ReturnableSale | null>(null);
  const [searching, setSearching] = useState(false);
  const [qtys, setQtys] = useState<Record<string, number>>({});
  const [restock, setRestock] = useState<Record<string, boolean>>({});
  const [method, setMethod] = useState<RefundMethod>("exchange");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [recent, setRecent] = useState<RecentReturn[]>([]);
  const [note, setNote] = useState<(RecentReturn & { items?: ReturnableItem[] }) | null>(null);
  const [ctx, setCtx] = useState<ReturnContext | null>(null);
  const [showCamera, setShowCamera] = useState(false);

  const loadRecent = useCallback(async () => {
    const { data } = await supabase()
      .from("returns")
      .select("*, sale:sales(invoice_no)")
      .order("created_at", { ascending: false })
      .limit(20);
    setRecent((data ?? []) as RecentReturn[]);
  }, []);

  const find = useCallback(
    async (code: string) => {
      if (!code.trim()) return;
      setSearching(true);
      const db = supabase();
      // رقم الفاتورة، أو رابط/رمز QR المطبوع على الفاتورة
      const resolved = await db.rpc("resolve_invoice_ref", { p_ref: code.trim() });
      const invoiceNo = resolved.error ? code.trim() : (resolved.data as string);
      const { data, error } = await db.rpc("get_sale_for_return", { p_invoice_no: invoiceNo });
      if (error) {
        setSearching(false);
        setSale(null);
        setCtx(null);
        toast(errorMessage(error), "error");
        return;
      }
      const s = data as ReturnableSale;
      const { data: c } = await db.rpc("sale_return_context", { p_sale_id: s.id });
      setSearching(false);
      const context = c as ReturnContext | null;
      setCtx(context);
      setInvoice(s.invoice_no);
      setSale(s);
      setQtys({});
      setRestock(Object.fromEntries(s.items.map((i) => [i.id, true])));
      // فاتورة فيها آجل: الافتراضي إرجاع المبلغ إلى حساب العميل
      if (context && Number(context.on_account) > 0) setMethod("account");
      else setMethod((m) => (m === "account" && !context?.customer_id ? "exchange" : m));
    },
    [toast],
  );

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    loadRecent();
    const inv = params.get("invoice");
    if (inv) find(inv);
  }, [find, loadRecent, params]);

  // تقدير للعرض؛ الخادم يحسب المبلغ النهائي (ويعيد المتبقي بالضبط عند إرجاع آخر كمية)
  const refundFor = (i: ReturnableItem, qty: number) => (qty > 0 ? round2((Number(i.line_total) * qty) / i.qty) : 0);

  const total = sale ? round2(sale.items.reduce((s, i) => s + refundFor(i, qtys[i.id] ?? 0), 0)) : 0;
  const expired = sale ? sale.days_since > sale.return_days : false;
  const blocked = expired && profile.role === "cashier";

  const submit = async () => {
    if (!sale || total <= 0) return;
    setBusy(true);
    const items = sale.items
      .filter((i) => (qtys[i.id] ?? 0) > 0)
      .map((i) => ({ sale_item_id: i.id, qty: qtys[i.id], restock: restock[i.id] ?? true }));
    const { data, error } = await supabase().rpc("process_return", {
      p_sale_id: sale.id,
      p_items: items,
      p_refund_method: method,
      p_reason: reason || null,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    const returnId = data as string;
    if (method === "exchange") {
      toast("تم إنشاء رصيد الاستبدال — اختر الأصناف البديلة");
      router.push(`/pos?credit=${returnId}`);
      return;
    }
    toast(method === "account" ? "تم الإرجاع وإضافة المبلغ إلى حساب العميل" : "تم الإرجاع بنجاح");
    const { data: ret } = await supabase().from("returns").select("*, sale:sales(invoice_no)").eq("id", returnId).single();
    const returnedItems = sale.items
      .filter((i) => (qtys[i.id] ?? 0) > 0)
      .map((i) => ({ ...i, qty: qtys[i.id] }));
    setNote({ ...(ret as RecentReturn), items: returnedItems });
    setSale(null);
    setCtx(null);
    setInvoice("");
    setReason("");
    loadRecent();
  };

  const methods = (Object.keys(REFUND_LABELS) as RefundMethod[]).filter((m) => m !== "account" || !!ctx?.customer_id);
  const overDirect =
    ctx?.max_direct_refund != null && method !== "account" && total > Number(ctx.max_direct_refund) + 0.001;

  if (!settings.allow_cashier_returns && profile.role === "cashier") {
    return (
      <div className="p-6">
        <EmptyState title="عمليات الإرجاع متاحة للمدير فقط" />
      </div>
    );
  }

  return (
    <div className="p-4 md:p-6">
      <PageHeader title="المرتجعات والاستبدال" subtitle={`مدة الإرجاع ${settings.return_days} أيام من تاريخ الفاتورة`} />

      <Card className="p-4">
        <form
          className="flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            find(invoice);
          }}
        >
          <Input
            dir="ltr"
            autoFocus
            className="h-12 text-base"
            placeholder="رقم الفاتورة INV-... أو امسح QR الفاتورة"
            value={invoice}
            onChange={(e) => setInvoice(e.target.value)}
            aria-label="رقم الفاتورة"
          />
          <CameraScanButton onClick={() => setShowCamera(true)} label="مسح QR الفاتورة" />
          <Button type="submit" size="lg" loading={searching}>
            <Search className="size-5" /> بحث
          </Button>
        </form>
      </Card>

      {sale && (
        <Card className="mt-4">
          <div className="flex flex-wrap items-center gap-3 border-b border-slate-100 p-4">
            <div className="flex-1">
              <p className="font-semibold">{sale.invoice_no}</p>
              <p className="text-sm text-slate-500">
                {dateTime(sale.created_at)} · {sale.customer_name ?? "عميل نقدي"} · منذ {sale.days_since} يوم
              </p>
            </div>
            <p className="font-bold">{money(sale.total)}</p>
            {expired && <Badge tone="red">تجاوزت مدة الإرجاع</Badge>}
          </div>
          {blocked && <p className="bg-red-50 p-3 text-sm text-red-700">انتهت مدة الإرجاع — يحتاج موافقة المدير.</p>}
          <Table>
            <thead>
              <tr>
                <th>الصنف</th>
                <th>المباع</th>
                <th>مرتجع سابقاً</th>
                <th>كمية الإرجاع</th>
                <th>إعادة للمخزون</th>
                <th>المبلغ</th>
              </tr>
            </thead>
            <tbody>
              {sale.items.map((i) => {
                const remaining = i.qty - i.returned_qty;
                const q = qtys[i.id] ?? 0;
                return (
                  <tr key={i.id} className={cn(remaining === 0 && "opacity-50")}>
                    <td>
                      <p className="font-medium">{i.product_name}</p>
                      <p className="text-xs text-slate-500">{i.variant_label}</p>
                    </td>
                    <td>{i.qty}</td>
                    <td>{i.returned_qty || "-"}</td>
                    <td>
                      <Input
                        type="number"
                        min={0}
                        max={remaining}
                        disabled={remaining === 0 || blocked}
                        className="h-9 w-20"
                        value={q || ""}
                        onChange={(e) => setQtys({ ...qtys, [i.id]: Math.min(Math.max(Number(e.target.value) || 0, 0), remaining) })}
                      />
                    </td>
                    <td>
                      <input
                        type="checkbox"
                        className="size-4 accent-brand-700"
                        checked={restock[i.id] ?? true}
                        onChange={(e) => setRestock({ ...restock, [i.id]: e.target.checked })}
                        title="ألغِ التحديد إذا كانت القطعة تالفة"
                      />
                    </td>
                    <td className="font-medium">{q > 0 ? money(refundFor(i, q)) : "-"}</td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
          <div className="grid gap-4 border-t border-slate-100 p-4 md:grid-cols-3">
            <Field label="طريقة الاسترداد">
              <Select value={method} onChange={(e) => setMethod(e.target.value as RefundMethod)} aria-label="طريقة الاسترداد">
                {methods.map((m) => (
                  <option key={m} value={m}>
                    {REFUND_LABELS[m]}
                  </option>
                ))}
              </Select>
            </Field>
            <Field label="السبب" className="md:col-span-2">
              <Textarea className="min-h-10" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مقاس غير مناسب، عيب صناعة..." />
            </Field>
          </div>
          {ctx && (Number(ctx.on_account) > 0 || Number(ctx.loyalty_points_earned) > 0 || Number(ctx.loyalty_points_redeemed) > 0) && (
            <div className="space-y-1 border-t border-slate-100 bg-slate-50 p-4 text-sm text-slate-700" data-testid="return-context">
              {Number(ctx.on_account) > 0 && (
                <p>
                  الفاتورة فيها {money(ctx.on_account)} آجل. الحد الأقصى للرد نقداً/شبكة/استبدال:{" "}
                  <span className="font-semibold">{money(ctx.max_direct_refund ?? 0)}</span> — والباقي «إلى حساب العميل».
                </p>
              )}
              {Number(ctx.loyalty_points_earned) > 0 && <p>ستُعكس نقاط الفاتورة ({ctx.loyalty_points_earned}) بنسبة المرتجع.</p>}
              {Number(ctx.loyalty_points_redeemed) > 0 && <p>ستُسترجع النقاط المستبدلة ({ctx.loyalty_points_redeemed}) بنسبة المرتجع.</p>}
            </div>
          )}
          {overDirect && (
            <p className="bg-red-50 p-3 text-sm text-red-700">
              المبلغ يتجاوز ما دُفع فعلاً ({money(ctx!.max_direct_refund ?? 0)}) — اختر «إلى حساب العميل».
            </p>
          )}
          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-100 p-4">
            <p className="text-lg">
              مبلغ الإرجاع: <span className="font-bold text-red-600">{money(total)}</span>
            </p>
            <Button size="lg" onClick={submit} loading={busy} disabled={total <= 0 || blocked || overDirect}>
              {method === "exchange" ? (
                <>
                  <Repeat className="size-5" /> متابعة للاستبدال
                </>
              ) : (
                <>
                  <Undo2 className="size-5" /> تنفيذ الإرجاع
                </>
              )}
            </Button>
          </div>
        </Card>
      )}

      <Card className="mt-6">
        <p className="border-b border-slate-100 p-4 font-semibold">آخر المرتجعات</p>
        {recent.length === 0 ? (
          <EmptyState title="لا توجد مرتجعات" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>رقم المرتجع</th>
                <th>الفاتورة</th>
                <th>التاريخ</th>
                <th>الطريقة</th>
                <th>المبلغ</th>
                <th>الحالة</th>
              </tr>
            </thead>
            <tbody>
              {recent.map((r) => (
                <tr key={r.id}>
                  <td className="font-medium">{r.return_no}</td>
                  <td>{r.sale?.invoice_no}</td>
                  <td className="ltr-nums text-slate-600">{dateTime(r.created_at)}</td>
                  <td>{REFUND_LABELS[r.refund_method]}</td>
                  <td className="font-semibold text-red-600">{money(r.total)}</td>
                  <td>
                    {r.refund_method === "exchange" ? (
                      r.credit_used_by_sale ? (
                        <Badge tone="green">تم الاستبدال</Badge>
                      ) : (
                        <button onClick={() => router.push(`/pos?credit=${r.id}`)}>
                          <Badge tone="violet">رصيد متاح — استخدام</Badge>
                        </button>
                      )
                    ) : (
                      <Badge>مسترد</Badge>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      <CameraScanner
        open={showCamera}
        withQr
        title="مسح QR أو باركود الفاتورة"
        onClose={() => setShowCamera(false)}
        onDetected={(code) => {
          setShowCamera(false);
          setInvoice(code);
          find(code);
        }}
      />

      {note && (
        <>
          <Modal
            open
            onClose={() => setNote(null)}
            title="إشعار دائن (مرتجع)"
            footer={
              <Button onClick={printNow}>
                <Printer className="size-4" /> طباعة
              </Button>
            }
          >
            <CreditNote note={note} storeName={settings.store_name} vatNumber={settings.vat_number} />
          </Modal>
          <PrintPortal>
            <CreditNote note={note} storeName={settings.store_name} vatNumber={settings.vat_number} />
          </PrintPortal>
        </>
      )}
    </div>
  );
}

function CreditNote({
  note,
  storeName,
  vatNumber,
}: {
  note: RecentReturn & { items?: ReturnableItem[] };
  storeName: string;
  vatNumber: string | null;
}) {
  return (
    <div className="receipt mx-auto" dir="rtl">
      <div style={{ textAlign: "center" }}>
        <div style={{ fontSize: "1.3em", fontWeight: 700 }}>{storeName}</div>
        {vatNumber && <div>الرقم الضريبي: {vatNumber}</div>}
        <div style={{ fontWeight: 700, marginTop: 4 }}>إشعار دائن — مرتجع</div>
      </div>
      <div className="dashed" />
      <div>رقم المرتجع: {note.return_no}</div>
      <div>الفاتورة الأصلية: {note.sale?.invoice_no}</div>
      <div className="ltr-nums">{dateTime(note.created_at)}</div>
      <div className="dashed" />
      <table>
        <tbody>
          {note.items?.map((i) => (
            <tr key={i.id}>
              <td>
                {i.product_name} {i.variant_label && `(${i.variant_label})`}
              </td>
              <td style={{ textAlign: "left" }}>× {i.qty}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="dashed" />
      <div>الضريبة المستردة: {Number(note.vat_amount).toFixed(2)}</div>
      <div style={{ fontWeight: 700, fontSize: "1.2em" }}>المبلغ المسترد: {Number(note.total).toFixed(2)} ر.س</div>
      <div>طريقة الاسترداد: {REFUND_LABELS[note.refund_method]}</div>
      {note.reason && <div>السبب: {note.reason}</div>}
    </div>
  );
}
