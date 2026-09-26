"use client";

import { FilePlus2, PackageCheck, XCircle } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { PurchaseAttachments } from "@/components/purchase-attachments";
import { Badge, Button, Card, Field, Input, Modal, Table, Textarea, useToast } from "@/components/ui";
import { dateTime, errorMessage, money, variantLabel } from "@/lib/format";
import { newRef } from "@/lib/inventory";
import { INVOICE_STATUS, type SupplierInvoice } from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";
import type { PurchaseOrder } from "@/lib/types";

interface Line {
  id: string;
  variant_id: string;
  qty: number;
  qty_received: number;
  qty_invoiced: number;
  qty_returned: number;
  unit_cost: number;
  variant: { sku: string; size: string | null; color: string | null; product: { name: string } };
}

interface Receipt {
  id: string;
  grn_no: string;
  received_at: string;
  is_historical: boolean;
  items: Array<{ qty: number; qty_invoiced: number; qty_returned: number }>;
}

/** الاستلام الجزئي، إغلاق المتبقي، سندات الاستلام، فواتير المورد، والمرفقات لأمر شراء */
export function PurchaseDocuments({ po, onChange }: { po: PurchaseOrder; onChange: () => void }) {
  const toast = useToast();
  const [lines, setLines] = useState<Line[]>([]);
  const [receipts, setReceipts] = useState<Receipt[]>([]);
  const [invoices, setInvoices] = useState<SupplierInvoice[]>([]);
  const [qty, setQty] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [closing, setClosing] = useState(false);
  const ref = useRef(newRef());

  const load = useCallback(async () => {
    const db = supabase();
    const [{ data: ls }, { data: rs }, { data: inv }] = await Promise.all([
      db.from("purchase_items").select("id, variant_id, qty, qty_received, qty_invoiced, qty_returned, unit_cost, variant:product_variants(sku, size, color, product:products(name))")
        .eq("purchase_id", po.id).order("id"),
      db.from("goods_receipts").select("id, grn_no, received_at, is_historical, items:goods_receipt_items(qty, qty_invoiced, qty_returned)")
        .eq("purchase_order_id", po.id).order("received_at"),
      db.from("supplier_invoices").select("*").eq("purchase_order_id", po.id).order("created_at"),
    ]);
    setLines((ls ?? []) as unknown as Line[]);
    setReceipts((rs ?? []) as Receipt[]);
    setInvoices((inv ?? []) as SupplierInvoice[]);
  }, [po.id]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const canReceive = po.status === "ordered" || po.status === "partially_received";
  const remaining = lines.reduce((a, l) => a + l.qty - l.qty_received, 0);
  const uninvoiced = receipts.reduce((a, r) => a + r.items.reduce((b, i) => b + i.qty - i.qty_invoiced - i.qty_returned, 0), 0);

  const receive = async () => {
    const items = Object.entries(qty).filter(([, v]) => Number(v) > 0).map(([purchase_item_id, v]) => ({ purchase_item_id, qty: Number(v) }));
    if (!items.length) return toast("أدخل الكميات الواصلة", "error");
    setBusy(true);
    const { error } = await supabase().rpc("receive_goods", { p_po: po.id, p_items: items, p_notes: null, p_client_ref: ref.current });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    ref.current = newRef();
    setQty({});
    toast("تم الاستلام وتحديث المخزون");
    load();
    onChange();
  };

  if (po.status === "draft" || po.status === "cancelled") return null;

  return (
    <div className="mt-4 grid gap-4 lg:grid-cols-3">
      <div className="min-w-0 space-y-4 lg:col-span-2">
        {canReceive && remaining > 0 && (
          <Card>
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-slate-100 p-3">
              <h3 className="font-semibold text-slate-900">استلام جزئي — المتبقي {remaining} قطعة</h3>
              <div className="flex gap-2">
                <Button size="sm" variant="outline"
                  onClick={() => setQty(Object.fromEntries(lines.map((l) => [l.id, String(l.qty - l.qty_received)])))}>
                  تعبئة المتبقي
                </Button>
                <Button size="sm" onClick={receive} loading={busy}>
                  <PackageCheck className="size-4" /> استلام الكميات
                </Button>
                {po.status === "partially_received" && (
                  <Button size="sm" variant="ghost" onClick={() => setClosing(true)}>
                    <XCircle className="size-4" /> إغلاق المتبقي
                  </Button>
                )}
              </div>
            </div>
            <Table>
              <thead>
                <tr>
                  <th>الصنف</th>
                  <th>مطلوب</th>
                  <th>مستلم</th>
                  <th>المتبقي</th>
                  <th>الواصل الآن</th>
                </tr>
              </thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.id}>
                    <td>
                      <p className="font-medium">{l.variant.product.name}</p>
                      <p className="text-xs text-slate-500">{variantLabel(l.variant.size, l.variant.color)} · <span className="ltr-nums">{l.variant.sku}</span></p>
                    </td>
                    <td>{l.qty}</td>
                    <td>{l.qty_received}</td>
                    <td>{l.qty - l.qty_received}</td>
                    <td>
                      {l.qty > l.qty_received && (
                        <Input type="number" min={0} max={l.qty - l.qty_received} aria-label={`استلام ${l.variant.sku}`} className="h-9 w-20"
                          value={qty[l.id] ?? ""} onChange={(e) => setQty((q) => ({ ...q, [l.id]: e.target.value }))} />
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </Card>
        )}

        <Card>
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-slate-100 p-3">
            <h3 className="font-semibold text-slate-900">سندات الاستلام والفواتير</h3>
            {uninvoiced > 0 && (
              <Link href={`/purchases/invoices/new?po=${po.id}`}>
                <Button size="sm">
                  <FilePlus2 className="size-4" /> تسجيل فاتورة المورد ({uninvoiced} قطعة غير مفوترة)
                </Button>
              </Link>
            )}
          </div>
          <Table>
            <thead>
              <tr>
                <th>المستند</th>
                <th>التاريخ</th>
                <th>التفاصيل</th>
                <th>الحالة</th>
              </tr>
            </thead>
            <tbody>
              {receipts.map((r) => {
                const q = r.items.reduce((a, i) => a + i.qty, 0);
                const inv = r.items.reduce((a, i) => a + i.qty_invoiced, 0);
                return (
                  <tr key={r.id}>
                    <td className="ltr-nums font-medium">{r.grn_no}</td>
                    <td className="ltr-nums text-xs">{dateTime(r.received_at)}</td>
                    <td className="text-sm">استلام {q} قطعة · مفوتر {inv}</td>
                    <td>{r.is_historical ? <Badge>قبل الترقية</Badge> : inv >= q ? <Badge tone="green">مفوتر</Badge> : <Badge tone="amber">بانتظار الفاتورة</Badge>}</td>
                  </tr>
                );
              })}
              {invoices.map((i) => (
                <tr key={i.id}>
                  <td>
                    <Link href={`/purchases/invoices/${i.id}`} className="ltr-nums font-medium text-brand-700 hover:underline">
                      {i.doc_no}
                    </Link>
                    <span className="ltr-nums block text-xs text-slate-500">{i.supplier_invoice_no}</span>
                  </td>
                  <td className="ltr-nums text-xs">{i.invoice_date}</td>
                  <td className="text-sm">{money(i.total)} · مسدَّد {money(i.settled_amount)}</td>
                  <td><Badge tone={INVOICE_STATUS[i.status].tone}>{INVOICE_STATUS[i.status].label}</Badge></td>
                </tr>
              ))}
              {receipts.length === 0 && invoices.length === 0 && (
                <tr>
                  <td colSpan={4} className="py-6 text-center text-slate-500">لم يُستلم شيء بعد</td>
                </tr>
              )}
            </tbody>
          </Table>
          {po.close_reason && <p className="border-t border-slate-100 p-3 text-sm text-slate-600">أُغلق المتبقي: {po.close_reason}</p>}
        </Card>
      </div>
      <PurchaseAttachments ownerType="purchase_order" ownerId={po.id} />

      {closing && <CloseModal poId={po.id} onClose={() => setClosing(false)} onDone={() => (setClosing(false), load(), onChange())} />}
    </div>
  );
}

function CloseModal({ poId, onClose, onDone }: { poId: string; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <Modal open onClose={onClose} title="إغلاق المتبقي من أمر الشراء" size="sm"
      footer={
        <Button variant="danger" disabled={!reason.trim()} loading={busy}
          onClick={async () => {
            setBusy(true);
            const { error } = await supabase().rpc("close_purchase_order", { p_id: poId, p_reason: reason.trim() });
            setBusy(false);
            if (error) return toast(errorMessage(error), "error");
            toast("أُغلق أمر الشراء — المتبقي لم يعد مطلوباً");
            onDone();
          }}>
          إغلاق
        </Button>
      }>
      <Field label="السبب (إلزامي)">
        <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="المورد لن يورّد الباقي" />
      </Field>
      <p className="mt-2 text-xs text-slate-500">المستلم يبقى كما هو، والمتبقي يُحذف من «مطلوب من المورد» في مركز القرارات.</p>
    </Modal>
  );
}
