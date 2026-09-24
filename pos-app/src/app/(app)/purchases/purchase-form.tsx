"use client";

import { ArrowRight, PackageCheck, Trash2, XCircle } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, ConfirmDialog, Field, Input, Loading, PageHeader, Select, Table, Textarea, useToast } from "@/components/ui";
import { VariantSearch } from "@/components/variant-search";
import { PURCHASE_STATUS_LABELS, dateTime, errorMessage, money, round2, variantLabel } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { CatalogItem, PurchaseOrder, PurchaseStatus, Supplier } from "@/lib/types";

interface Line {
  variant_id: string;
  name: string;
  label: string;
  sku: string;
  qty: string;
  unit_cost: string;
}

export function PurchaseForm({ id }: { id: string | null }) {
  const router = useRouter();
  const toast = useToast();
  const { settings } = useSession();
  const [loading, setLoading] = useState(!!id);
  const [po, setPo] = useState<PurchaseOrder | null>(null);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [supplierId, setSupplierId] = useState("");
  const [invoiceNo, setInvoiceNo] = useState("");
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState<Line[]>([]);
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState<"receive" | "cancel" | null>(null);

  useEffect(() => {
    const db = supabase();
    db.from("suppliers")
      .select("*")
      .eq("is_active", true)
      .order("name")
      .then(({ data }) => setSuppliers((data ?? []) as Supplier[]));
    if (!id) return;
    (async () => {
      const [{ data: p }, { data: items }] = await Promise.all([
        db.from("purchase_orders").select("*").eq("id", id).single(),
        db
          .from("purchase_items")
          .select("variant_id, qty, unit_cost, variant:product_variants(sku, size, color, product:products(name))")
          .eq("purchase_id", id),
      ]);
      const order = p as PurchaseOrder;
      setPo(order);
      setSupplierId(order.supplier_id);
      setInvoiceNo(order.supplier_invoice_no ?? "");
      setNotes(order.notes ?? "");
      setLines(
        ((items ?? []) as unknown as Array<{
          variant_id: string;
          qty: number;
          unit_cost: number;
          variant: { sku: string; size: string | null; color: string | null; product: { name: string } };
        }>).map((i) => ({
          variant_id: i.variant_id,
          name: i.variant.product.name,
          label: variantLabel(i.variant.size, i.variant.color),
          sku: i.variant.sku,
          qty: String(i.qty),
          unit_cost: String(i.unit_cost),
        })),
      );
      setLoading(false);
    })();
  }, [id]);

  const editable = !po || po.status === "draft" || po.status === "ordered";

  const addLine = async (item: CatalogItem) => {
    const existing = lines.find((l) => l.variant_id === item.variant_id);
    if (existing) {
      setLines((ls) => ls.map((l) => (l.variant_id === item.variant_id ? { ...l, qty: String(Number(l.qty) + 1) } : l)));
      return;
    }
    const { data } = await supabase().from("variant_costs").select("cost_price").eq("variant_id", item.variant_id).maybeSingle();
    setLines((ls) => [
      ...ls,
      {
        variant_id: item.variant_id,
        name: item.product_name,
        label: variantLabel(item.size, item.color),
        sku: item.sku,
        qty: "1",
        unit_cost: String((data as { cost_price: number } | null)?.cost_price ?? 0),
      },
    ]);
  };

  const subtotal = round2(lines.reduce((s, l) => s + (Number(l.qty) || 0) * (Number(l.unit_cost) || 0), 0));
  const vat = round2((subtotal * Number(settings.vat_rate)) / 100);

  const save = async (status: PurchaseStatus): Promise<string | null> => {
    if (!supplierId) {
      toast("اختر المورد", "error");
      return null;
    }
    if (lines.length === 0 || lines.some((l) => !(Number(l.qty) > 0))) {
      toast("أضف أصنافاً بكميات صحيحة", "error");
      return null;
    }
    setBusy(true);
    const db = supabase();
    try {
      let poId = id;
      const header = { supplier_id: supplierId, supplier_invoice_no: invoiceNo.trim() || null, notes: notes.trim() || null, status };
      if (poId) {
        const { error } = await db.from("purchase_orders").update(header).eq("id", poId);
        if (error) throw error;
        const { error: delErr } = await db.from("purchase_items").delete().eq("purchase_id", poId);
        if (delErr) throw delErr;
      } else {
        const { data: no, error: noErr } = await db.rpc("next_po_no");
        if (noErr) throw noErr;
        const { data, error } = await db
          .from("purchase_orders")
          .insert({ ...header, po_no: no as string })
          .select("id")
          .single();
        if (error) throw error;
        poId = (data as { id: string }).id;
      }
      const { error } = await db.from("purchase_items").insert(
        lines.map((l) => ({ purchase_id: poId, variant_id: l.variant_id, qty: Number(l.qty), unit_cost: Number(l.unit_cost) || 0 })),
      );
      if (error) throw error;
      return poId;
    } catch (e) {
      toast(errorMessage(e), "error");
      return null;
    } finally {
      setBusy(false);
    }
  };

  const onSave = async (status: PurchaseStatus) => {
    const poId = await save(status);
    if (!poId) return;
    toast("تم حفظ أمر الشراء");
    if (!id) router.replace(`/purchases/${poId}`);
    else setPo((p) => (p ? { ...p, status } : p));
  };

  const receive = async () => {
    const poId = await save(po?.status === "ordered" ? "ordered" : "draft");
    if (!poId) return;
    setBusy(true);
    const { error } = await supabase().rpc("receive_purchase", { p_purchase_id: poId });
    setBusy(false);
    setConfirm(null);
    if (error) return toast(errorMessage(error), "error");
    toast("تم استلام البضاعة وتحديث المخزون والتكلفة");
    router.push("/purchases");
  };

  const cancel = async () => {
    if (!id) return;
    setBusy(true);
    const { error } = await supabase().from("purchase_orders").update({ status: "cancelled" }).eq("id", id);
    setBusy(false);
    setConfirm(null);
    if (error) return toast(errorMessage(error), "error");
    router.push("/purchases");
  };

  if (loading) return <Loading />;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={po ? `أمر شراء ${po.po_no}` : "أمر شراء جديد"}
        subtitle={po?.received_at ? `تم الاستلام ${dateTime(po.received_at)}` : undefined}
        actions={
          <>
            <Link href="/purchases">
              <Button variant="ghost">
                <ArrowRight className="size-4" /> رجوع
              </Button>
            </Link>
            {po && <Badge tone={po.status === "received" ? "green" : "slate"}>{PURCHASE_STATUS_LABELS[po.status]}</Badge>}
            {editable && (
              <>
                {po && (
                  <Button variant="outline" onClick={() => setConfirm("cancel")}>
                    <XCircle className="size-4" /> إلغاء الأمر
                  </Button>
                )}
                <Button variant="outline" onClick={() => onSave("draft")} loading={busy}>
                  حفظ كمسودة
                </Button>
                <Button variant="secondary" onClick={() => onSave("ordered")} loading={busy}>
                  حفظ كمطلوب
                </Button>
                <Button onClick={() => setConfirm("receive")} disabled={busy || lines.length === 0}>
                  <PackageCheck className="size-4" /> استلام البضاعة
                </Button>
              </>
            )}
          </>
        }
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="space-y-3 p-4">
          <Field label="المورد *">
            <Select value={supplierId} onChange={(e) => setSupplierId(e.target.value)} disabled={!editable}>
              <option value="">اختر المورد</option>
              {suppliers.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </Select>
          </Field>
          {suppliers.length === 0 && (
            <Link href="/suppliers" className="text-sm text-brand-700 hover:underline">
              أضف مورداً أولاً
            </Link>
          )}
          <Field label="رقم فاتورة المورد">
            <Input dir="ltr" value={invoiceNo} onChange={(e) => setInvoiceNo(e.target.value)} disabled={!editable} />
          </Field>
          <Field label="ملاحظات">
            <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={!editable} />
          </Field>
          <div className="space-y-1 border-t border-slate-100 pt-3 text-sm">
            <div className="flex justify-between">
              <span className="text-slate-600">الإجمالي قبل الضريبة</span>
              <span>{money(subtotal)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-slate-600">ضريبة المدخلات {Number(settings.vat_rate)}%</span>
              <span>{money(vat)}</span>
            </div>
            <div className="flex justify-between text-base font-bold">
              <span>الإجمالي</span>
              <span>{money(subtotal + vat)}</span>
            </div>
          </div>
        </Card>

        <Card className="lg:col-span-2">
          {editable && (
            <div className="border-b border-slate-100 p-3">
              <VariantSearch onPick={addLine} />
            </div>
          )}
          <Table>
            <thead>
              <tr>
                <th>الصنف</th>
                <th>الكمية</th>
                <th>تكلفة الوحدة (قبل الضريبة)</th>
                <th>الإجمالي</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {lines.map((l, i) => (
                <tr key={l.variant_id}>
                  <td>
                    <p className="font-medium">{l.name}</p>
                    <p className="text-xs text-slate-500">
                      {l.label} · <span dir="ltr">{l.sku}</span>
                    </p>
                  </td>
                  <td>
                    <Input
                      type="number"
                      min={1}
                      className="h-9 w-20"
                      disabled={!editable}
                      value={l.qty}
                      onChange={(e) => setLines((ls) => ls.map((x, idx) => (idx === i ? { ...x, qty: e.target.value } : x)))}
                    />
                  </td>
                  <td>
                    <Input
                      type="number"
                      step="0.01"
                      min={0}
                      className="h-9 w-28"
                      disabled={!editable}
                      value={l.unit_cost}
                      onChange={(e) => setLines((ls) => ls.map((x, idx) => (idx === i ? { ...x, unit_cost: e.target.value } : x)))}
                    />
                  </td>
                  <td className="font-medium">{money((Number(l.qty) || 0) * (Number(l.unit_cost) || 0))}</td>
                  <td>
                    {editable && (
                      <button className="p-1.5 text-slate-400 hover:text-red-600" onClick={() => setLines(lines.filter((_, idx) => idx !== i))} aria-label="حذف">
                        <Trash2 className="size-4" />
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {lines.length === 0 && (
                <tr>
                  <td colSpan={5} className="py-10 text-center text-slate-500">
                    امسح أو ابحث لإضافة أصناف. لصنف جديد، أنشئه أولاً من صفحة المنتجات.
                  </td>
                </tr>
              )}
            </tbody>
          </Table>
        </Card>
      </div>

      <ConfirmDialog
        open={confirm === "receive"}
        title="استلام البضاعة"
        message="سيتم إضافة الكميات إلى المخزون وتحديث متوسط التكلفة لكل صنف. لا يمكن تعديل الأمر بعد الاستلام."
        confirmLabel="تأكيد الاستلام"
        loading={busy}
        onConfirm={receive}
        onClose={() => setConfirm(null)}
      />
      <ConfirmDialog
        open={confirm === "cancel"}
        title="إلغاء أمر الشراء"
        message="لن يتم تعديل المخزون."
        tone="danger"
        confirmLabel="إلغاء الأمر"
        loading={busy}
        onConfirm={cancel}
        onClose={() => setConfirm(null)}
      />
    </div>
  );
}
