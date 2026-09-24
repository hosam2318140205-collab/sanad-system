"use client";

import { ClipboardCheck, History, Search, SlidersHorizontal } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Stat, Table, useToast } from "@/components/ui";
import { normalize } from "@/lib/catalog";
import { errorMessage, money, num, variantLabel } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Category } from "@/lib/types";

interface Row {
  id: string;
  sku: string;
  barcode: string | null;
  size: string | null;
  color: string | null;
  stock_qty: number;
  low_stock_threshold: number;
  price: number | null;
  is_active: boolean;
  product: { id: string; name: string; base_price: number; category_id: string | null; image_url: string | null };
  cost: { cost_price: number } | null;
}

export function InventoryScreen() {
  const toast = useToast();
  const [rows, setRows] = useState<Row[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState("");
  const [cat, setCat] = useState("");
  const [filter, setFilter] = useState<"all" | "low" | "out" | "negative">("all");
  const [adjust, setAdjust] = useState<Row | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const db = supabase();
    const all: Row[] = [];
    for (let from = 0; ; from += 1000) {
      const { data, error } = await db
        .from("product_variants")
        .select(
          "id, sku, barcode, size, color, stock_qty, low_stock_threshold, price, is_active, product:products!inner(id, name, base_price, category_id, image_url), cost:variant_costs(cost_price)",
        )
        .eq("is_active", true)
        .order("stock_qty")
        .range(from, from + 999);
      if (error) {
        toast(errorMessage(error), "error");
        break;
      }
      all.push(...((data ?? []) as unknown as Row[]));
      if (!data || data.length < 1000) break;
    }
    const { data: cats } = await db.from("categories").select("*").order("sort_order");
    setRows(all);
    setCategories((cats ?? []) as Category[]);
    setLoading(false);
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const filtered = useMemo(() => {
    const term = normalize(q);
    return rows.filter((r) => {
      if (cat && r.product.category_id !== cat) return false;
      if (filter === "low" && r.stock_qty > r.low_stock_threshold) return false;
      if (filter === "out" && r.stock_qty > 0) return false;
      if (filter === "negative" && r.stock_qty >= 0) return false;
      if (!term) return true;
      return normalize(r.product.name).includes(term) || r.sku.toLowerCase().includes(term) || r.barcode?.includes(term);
    });
  }, [rows, q, cat, filter]);

  const totals = useMemo(() => {
    let units = 0;
    let cost = 0;
    let retail = 0;
    let low = 0;
    for (const r of rows) {
      const qty = Math.max(r.stock_qty, 0);
      units += qty;
      cost += qty * Number(r.cost?.cost_price ?? 0);
      retail += qty * Number(r.price ?? r.product.base_price);
      if (r.stock_qty <= r.low_stock_threshold) low++;
    }
    return { units, cost, retail, low };
  }, [rows]);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="المخزون"
        actions={
          <>
            <Link href="/inventory/movements">
              <Button variant="outline">
                <History className="size-4" /> حركات المخزون
              </Button>
            </Link>
            <Link href="/inventory/counts">
              <Button>
                <ClipboardCheck className="size-4" /> الجرد
              </Button>
            </Link>
          </>
        }
      />
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="إجمالي القطع" value={num(totals.units)} />
        <Stat label="قيمة المخزون (تكلفة)" value={money(totals.cost)} />
        <Stat label="قيمة المخزون (بيع)" value={money(totals.retail)} />
        <Stat label="أصناف منخفضة" value={num(totals.low)} tone="amber" />
      </div>
      <Card>
        <div className="flex flex-wrap gap-2 border-b border-slate-100 p-3">
          <div className="relative min-w-52 flex-1">
            <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <Input className="ps-9" placeholder="بحث بالاسم / SKU / باركود" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
          <Select className="w-auto" value={cat} onChange={(e) => setCat(e.target.value)}>
            <option value="">كل التصنيفات</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
          <Select className="w-auto" value={filter} onChange={(e) => setFilter(e.target.value as typeof filter)}>
            <option value="all">الكل</option>
            <option value="low">منخفض</option>
            <option value="out">نفد</option>
            <option value="negative">سالب</option>
          </Select>
        </div>
        {loading ? (
          <Loading />
        ) : filtered.length === 0 ? (
          <EmptyState title="لا توجد أصناف" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>المنتج</th>
                <th>المقاس / اللون</th>
                <th>SKU</th>
                <th>الكمية</th>
                <th>التكلفة</th>
                <th>القيمة</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {filtered.slice(0, 500).map((r) => (
                <tr key={r.id}>
                  <td>
                    <Link href={`/products/${r.product.id}`} className="font-medium hover:text-brand-700">
                      {r.product.name}
                    </Link>
                  </td>
                  <td>{variantLabel(r.size, r.color) || "-"}</td>
                  <td className="ltr-nums text-xs text-slate-500">{r.sku}</td>
                  <td>
                    <Badge tone={r.stock_qty <= 0 ? "red" : r.stock_qty <= r.low_stock_threshold ? "amber" : "green"}>{r.stock_qty}</Badge>
                  </td>
                  <td>{money(r.cost?.cost_price ?? 0)}</td>
                  <td>{money(Math.max(r.stock_qty, 0) * Number(r.cost?.cost_price ?? 0))}</td>
                  <td className="text-end">
                    <Button size="sm" variant="outline" onClick={() => setAdjust(r)}>
                      <SlidersHorizontal className="size-4" /> تسوية
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
        {filtered.length > 500 && <p className="p-3 text-center text-sm text-slate-500">يتم عرض أول 500 صنف — استخدم البحث للتصفية</p>}
      </Card>

      {adjust && (
        <AdjustModal
          row={adjust}
          onClose={() => setAdjust(null)}
          onDone={(newQty) => {
            setRows((rs) => rs.map((r) => (r.id === adjust.id ? { ...r, stock_qty: newQty } : r)));
            setAdjust(null);
          }}
        />
      )}
    </div>
  );
}

const REASONS = ["تالف", "مفقود / سرقة", "هدية / عينة", "تصحيح إدخال", "استلام بدون أمر شراء", "أخرى"];

function AdjustModal({ row, onClose, onDone }: { row: Row; onClose: () => void; onDone: (qty: number) => void }) {
  const toast = useToast();
  const [mode, setMode] = useState<"add" | "remove" | "set">("remove");
  const [qty, setQty] = useState("");
  const [reason, setReason] = useState(REASONS[0]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  const n = Number(qty) || 0;
  const change = mode === "add" ? n : mode === "remove" ? -n : n - row.stock_qty;

  const submit = async () => {
    if (change === 0) return;
    setBusy(true);
    const { data, error } = await supabase().rpc("adjust_stock", {
      p_variant_id: row.id,
      p_qty_change: change,
      p_note: note ? `${reason}: ${note}` : reason,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم تعديل المخزون");
    onDone(data as number);
  };

  return (
    <Modal
      open
      onClose={onClose}
      title={`تسوية: ${row.product.name} ${variantLabel(row.size, row.color)}`}
      size="sm"
      footer={
        <Button onClick={submit} loading={busy} disabled={change === 0}>
          حفظ ({change > 0 ? "+" : ""}
          {change})
        </Button>
      }
    >
      <div className="space-y-3">
        <p className="text-sm text-slate-600">
          الكمية الحالية: <b>{row.stock_qty}</b> ← الجديدة: <b>{row.stock_qty + change}</b>
        </p>
        <Select value={mode} onChange={(e) => setMode(e.target.value as typeof mode)}>
          <option value="remove">خصم كمية</option>
          <option value="add">إضافة كمية</option>
          <option value="set">تحديد الكمية الفعلية</option>
        </Select>
        <Input type="number" min={0} autoFocus value={qty} onChange={(e) => setQty(e.target.value)} placeholder="الكمية" />
        <Field label="السبب">
          <Select value={reason} onChange={(e) => setReason(e.target.value)}>
            {REASONS.map((r) => (
              <option key={r}>{r}</option>
            ))}
          </Select>
        </Field>
        <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="ملاحظة (اختياري)" />
      </div>
    </Modal>
  );
}
