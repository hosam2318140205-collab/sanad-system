"use client";

import { ArrowRight, CheckCircle2, ScanBarcode, XCircle } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CameraScanButton, CameraScanner, type ScanOutcome } from "@/components/camera-scanner";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, ConfirmDialog, Input, Loading, PageHeader, Select, Stat, Table, cn, useToast } from "@/components/ui";
import { fetchAllRows, normalize } from "@/lib/catalog";
import { errorMessage, num, variantLabel } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { StockCount } from "@/lib/types";

interface Item {
  id: string;
  variant_id: string;
  expected_qty: number;
  counted_qty: number | null;
  variant: { sku: string; barcode: string | null; size: string | null; color: string | null; product: { name: string } };
}

export function CountSheet({ id }: { id: string }) {
  const toast = useToast();
  const { isManager, profile } = useSession();
  const [count, setCount] = useState<StockCount | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [scan, setScan] = useState("");
  const [q, setQ] = useState("");
  const [view, setView] = useState<"all" | "uncounted" | "diff">("all");
  const [confirm, setConfirm] = useState<"apply" | "cancel" | null>(null);
  const [busy, setBusy] = useState(false);
  const [lastScanned, setLastScanned] = useState<string | null>(null);
  const scanRef = useRef<HTMLInputElement>(null);
  const [showCamera, setShowCamera] = useState(false);

  const load = useCallback(async () => {
    const db = supabase();
    const [{ data: c }, its] = await Promise.all([
      db.from("stock_counts").select("*").eq("id", id).single(),
      fetchAllRows<Item>((from, to) =>
        db
          .from("stock_count_items")
          .select("id, variant_id, expected_qty, counted_qty, variant:product_variants(sku, barcode, size, color, product:products(name))")
          .eq("count_id", id)
          .order("id")
          .range(from, to),
      ),
    ]);
    setCount(c as StockCount);
    const list = its.sort((a, b) => a.variant.product.name.localeCompare(b.variant.product.name, "ar"));
    setItems(list);
  }, [id]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const editable = count?.status === "open";
  const showExpected = isManager; // جرد أعمى للكاشير

  const saveQty = async (item: Item, qty: number | null) => {
    setItems((its) => its.map((i) => (i.id === item.id ? { ...i, counted_qty: qty } : i)));
    const { error } = await supabase()
      .from("stock_count_items")
      .update({ counted_qty: qty, counted_by: profile.id, counted_at: new Date().toISOString() })
      .eq("id", item.id);
    if (error) toast(errorMessage(error), "error");
  };

  // المسح المتتالي السريع (قارئ أو كاميرا) يقرأ آخر الكميات عبر ref وليس من حالة قديمة
  const itemsRef = useRef(items);
  useEffect(() => {
    itemsRef.current = items;
  });
  const scanCode = (code: string): ScanOutcome => {
    const lower = code.toLowerCase();
    const item = itemsRef.current.find((i) => i.variant.barcode === code || i.variant.sku.toLowerCase() === lower);
    if (!item) return { ok: false, message: `الصنف ${code} غير موجود في هذا الجرد` };
    const qty = (item.counted_qty ?? 0) + 1;
    itemsRef.current = itemsRef.current.map((i) => (i.id === item.id ? { ...i, counted_qty: qty } : i));
    saveQty(item, qty);
    setLastScanned(item.id);
    const label = variantLabel(item.variant.size, item.variant.color);
    return { ok: true, message: `${item.variant.product.name}${label ? ` (${label})` : ""} — المعدود ${qty}` };
  };

  const onScan = () => {
    const code = scan.trim();
    if (!code) return;
    setScan("");
    const outcome = scanCode(code);
    if (!outcome.ok) toast(outcome.message, "error");
  };

  const filtered = useMemo(() => {
    const term = normalize(q);
    return items.filter((i) => {
      if (view === "uncounted" && i.counted_qty !== null) return false;
      if (view === "diff" && (i.counted_qty === null || i.counted_qty === i.expected_qty)) return false;
      if (!term) return true;
      return normalize(i.variant.product.name).includes(term) || i.variant.sku.toLowerCase().includes(term);
    });
  }, [items, q, view]);

  const counted = items.filter((i) => i.counted_qty !== null).length;
  const diffs = items.filter((i) => i.counted_qty !== null && i.counted_qty !== i.expected_qty);
  const shortage = diffs.reduce((s, i) => s + Math.min(0, (i.counted_qty ?? 0) - i.expected_qty), 0);
  const surplus = diffs.reduce((s, i) => s + Math.max(0, (i.counted_qty ?? 0) - i.expected_qty), 0);

  const apply = async () => {
    setBusy(true);
    const { data, error } = await supabase().rpc("apply_stock_count", { p_count_id: id });
    setBusy(false);
    setConfirm(null);
    if (error) return toast(errorMessage(error), "error");
    toast(`تم اعتماد الجرد وتعديل ${data as number} صنف`);
    load();
  };

  const cancel = async () => {
    setBusy(true);
    const { error } = await supabase().from("stock_counts").update({ status: "cancelled" }).eq("id", id);
    setBusy(false);
    setConfirm(null);
    if (error) return toast(errorMessage(error), "error");
    load();
  };

  if (!count) return <Loading />;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={`جرد ${count.count_no}`}
        subtitle={count.notes ?? undefined}
        actions={
          <>
            <Link href="/inventory/counts">
              <Button variant="ghost">
                <ArrowRight className="size-4" /> رجوع
              </Button>
            </Link>
            {editable && isManager && (
              <>
                <Button variant="outline" onClick={() => setConfirm("cancel")}>
                  <XCircle className="size-4" /> إلغاء الجرد
                </Button>
                <Button onClick={() => setConfirm("apply")}>
                  <CheckCircle2 className="size-4" /> اعتماد الجرد
                </Button>
              </>
            )}
            {!editable && <Badge tone={count.status === "applied" ? "green" : "slate"}>{count.status === "applied" ? "معتمد" : "ملغي"}</Badge>}
          </>
        }
      />

      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="الأصناف" value={num(items.length)} />
        <Stat label="تم عدّها" value={`${num(counted)} / ${num(items.length)}`} tone="blue" />
        {showExpected && <Stat label="عجز (قطع)" value={num(shortage)} tone="red" />}
        {showExpected && <Stat label="زيادة (قطع)" value={num(surplus)} tone="green" />}
      </div>

      {editable && (
        <Card className="mb-4 p-4">
          <form
            onSubmit={(e) => {
              e.preventDefault();
              onScan();
            }}
            className="flex gap-2"
          >
            <div className="relative min-w-0 flex-1">
              <ScanBarcode className="pointer-events-none absolute start-3 top-1/2 size-5 -translate-y-1/2 text-slate-400" />
              <Input
                ref={scanRef}
                autoFocus
                className="h-12 ps-10 text-base"
                placeholder="امسح باركود القطعة — كل مسح يضيف 1"
                value={scan}
                onChange={(e) => setScan(e.target.value)}
              />
            </div>
            <CameraScanButton onClick={() => setShowCamera(true)} />
          </form>
        </Card>
      )}

      <Card>
        <div className="flex flex-wrap gap-2 border-b border-slate-100 p-3">
          <Input className="min-w-52 flex-1" placeholder="بحث" value={q} onChange={(e) => setQ(e.target.value)} />
          <Select className="w-auto" value={view} onChange={(e) => setView(e.target.value as typeof view)}>
            <option value="all">الكل</option>
            <option value="uncounted">لم يُعد</option>
            {showExpected && <option value="diff">فروقات</option>}
          </Select>
        </div>
        <Table>
          <thead>
            <tr>
              <th>الصنف</th>
              <th>SKU</th>
              {showExpected && <th>المتوقع</th>}
              <th>المعدود</th>
              {showExpected && <th>الفرق</th>}
            </tr>
          </thead>
          <tbody>
            {filtered.slice(0, 1000).map((i) => {
              const diff = i.counted_qty === null ? null : i.counted_qty - i.expected_qty;
              return (
                <tr key={i.id} className={cn(lastScanned === i.id && "bg-emerald-50")}>
                  <td>
                    <p className="font-medium">{i.variant.product.name}</p>
                    <p className="text-xs text-slate-500">{variantLabel(i.variant.size, i.variant.color)}</p>
                  </td>
                  <td className="ltr-nums text-xs text-slate-500">{i.variant.sku}</td>
                  {showExpected && <td>{i.expected_qty}</td>}
                  <td>
                    {editable ? (
                      <Input
                        type="number"
                        min={0}
                        className="h-9 w-24"
                        value={i.counted_qty ?? ""}
                        onChange={(e) => {
                          const v = e.target.value;
                          setItems((its) => its.map((x) => (x.id === i.id ? { ...x, counted_qty: v === "" ? null : Number(v) } : x)));
                        }}
                        onBlur={(e) => saveQty(i, e.target.value === "" ? null : Math.max(0, Number(e.target.value)))}
                      />
                    ) : (
                      (i.counted_qty ?? "-")
                    )}
                  </td>
                  {showExpected && (
                    <td>
                      {diff === null ? (
                        "-"
                      ) : diff === 0 ? (
                        <Badge tone="green">مطابق</Badge>
                      ) : (
                        <Badge tone={diff < 0 ? "red" : "blue"}>{diff > 0 ? `+${diff}` : diff}</Badge>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </Table>
      </Card>

      <CameraScanner
        open={showCamera}
        continuous
        title="جرد بالكاميرا — كل مسح يضيف 1"
        onClose={() => {
          setShowCamera(false);
          scanRef.current?.focus();
        }}
        onDetected={scanCode}
      />

      <ConfirmDialog
        open={confirm === "apply"}
        title="اعتماد الجرد"
        message={
          <>
            سيتم ضبط كميات {num(diffs.length)} صنف على الكميات المعدودة. الأصناف التي لم تُعد ({num(items.length - counted)}) لن تتغير.
          </>
        }
        confirmLabel="اعتماد"
        loading={busy}
        onConfirm={apply}
        onClose={() => setConfirm(null)}
      />
      <ConfirmDialog
        open={confirm === "cancel"}
        title="إلغاء الجرد"
        message="لن يتم تعديل أي كميات."
        tone="danger"
        confirmLabel="إلغاء الجرد"
        loading={busy}
        onConfirm={cancel}
        onClose={() => setConfirm(null)}
      />
    </div>
  );
}
