"use client";

import { Activity, ArrowLeftRight, ClipboardCheck, History, Search, SlidersHorizontal } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Stat, Table, useToast } from "@/components/ui";
import { normalize } from "@/lib/catalog";
import { errorMessage, money, num, variantLabel } from "@/lib/format";
import { fetchLocations, newRef, rpcAll, type Availability, type Location } from "@/lib/inventory";
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
  const [locations, setLocations] = useState<Location[]>([]);
  const [loc, setLoc] = useState("");
  const [avail, setAvail] = useState<Record<string, Availability> | null>(null);

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
    fetchLocations()
      .then(setLocations)
      .catch(() => setLocations([]));
  }, [load]);

  // عرض موقع محدد: الموجود / المحجوز / الصادر المعتمد / المتاح للبيع / القادم
  const loadAvail = useCallback(async () => {
    if (!loc) return setAvail(null);
    try {
      const list = await rpcAll<Availability>("location_availability", { p_location: loc });
      setAvail(Object.fromEntries(list.map((a) => [a.variant_id, a])));
    } catch (e) {
      toast(errorMessage(e), "error");
    }
  }, [loc, toast]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reload on location change
    loadAvail();
  }, [loadAvail]);
  const qtyOf = useCallback((r: Row) => (avail ? (avail[r.id]?.on_hand ?? 0) : r.stock_qty), [avail]);

  const filtered = useMemo(() => {
    const term = normalize(q);
    return rows.filter((r) => {
      if (cat && r.product.category_id !== cat) return false;
      const qty = qtyOf(r);
      if (filter === "low" && qty > r.low_stock_threshold) return false;
      if (filter === "out" && qty > 0) return false;
      if (filter === "negative" && qty >= 0) return false;
      if (!term) return true;
      return normalize(r.product.name).includes(term) || r.sku.toLowerCase().includes(term) || r.barcode?.includes(term);
    });
  }, [rows, q, cat, filter, qtyOf]);

  const totals = useMemo(() => {
    let units = 0;
    let cost = 0;
    let retail = 0;
    let low = 0;
    for (const r of rows) {
      const qty = Math.max(qtyOf(r), 0);
      units += qty;
      cost += qty * Number(r.cost?.cost_price ?? 0);
      retail += qty * Number(r.price ?? r.product.base_price);
      if (qtyOf(r) <= r.low_stock_threshold) low++;
    }
    return { units, cost, retail, low };
  }, [rows, qtyOf]);
  const multi = locations.length > 1;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="المخزون"
        actions={
          <>
            {multi && (
              <Select aria-label="الموقع" className="w-auto min-w-40" value={loc} onChange={(e) => setLoc(e.target.value)}>
                <option value="">كل المواقع (الإجمالي)</option>
                {locations.map((l) => (
                  <option key={l.id} value={l.id}>
                    {l.name}
                  </option>
                ))}
              </Select>
            )}
            {multi && (
              <Link href="/transfers">
                <Button variant="outline">
                  <ArrowLeftRight className="size-4" /> التحويلات
                </Button>
              </Link>
            )}
            <Link href="/inventory/insights">
              <Button variant="outline">
                <Activity className="size-4" /> التحليلات
              </Button>
            </Link>
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
                <th>{avail ? "الموجود" : "الكمية"}</th>
                {avail && <th>محجوز</th>}
                {avail && <th>صادر معتمد</th>}
                {avail && <th>المتاح للبيع</th>}
                {avail && <th>قادم</th>}
                {avail && <th>مطلوب من المورد</th>}
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
                    <Badge tone={qtyOf(r) <= 0 ? "red" : qtyOf(r) <= r.low_stock_threshold ? "amber" : "green"}>{qtyOf(r)}</Badge>
                  </td>
                  {avail && <td>{avail[r.id]?.reserved || "-"}</td>}
                  {avail && <td>{avail[r.id]?.outgoing || "-"}</td>}
                  {avail && <td className="font-semibold">{avail[r.id]?.available ?? 0}</td>}
                  {avail && <td>{(avail[r.id]?.in_transit ?? 0) + (avail[r.id]?.incoming_approved ?? 0) || "-"}</td>}
                  {avail && <td>{avail[r.id]?.on_order || "-"}</td>}
                  <td>{money(r.cost?.cost_price ?? 0)}</td>
                  <td>{money(Math.max(qtyOf(r), 0) * Number(r.cost?.cost_price ?? 0))}</td>
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
          locations={locations}
          defaultLocation={loc}
          onClose={() => setAdjust(null)}
          onDone={(change) => {
            setRows((rs) => rs.map((r) => (r.id === adjust.id ? { ...r, stock_qty: r.stock_qty + change } : r)));
            setAdjust(null);
            loadAvail();
          }}
        />
      )}
    </div>
  );
}

const REASONS = ["تالف", "مفقود / سرقة", "هدية / عينة", "تصحيح إدخال", "استلام بدون أمر شراء", "أخرى"];

function AdjustModal({
  row,
  locations,
  defaultLocation,
  onClose,
  onDone,
}: {
  row: Row;
  locations: Location[];
  defaultLocation: string;
  onClose: () => void;
  onDone: (change: number) => void;
}) {
  const toast = useToast();
  const [location, setLocation] = useState(defaultLocation || locations.find((l) => l.is_default)?.id || "");
  const [current, setCurrent] = useState<number | null>(null);
  const [mode, setMode] = useState<"add" | "remove" | "set">("remove");
  const [qty, setQty] = useState("");
  const [reason, setReason] = useState(REASONS[0]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());

  // الرصيد الحالي في الموقع المختار (التسوية تكون دائماً على موقع)
  useEffect(() => {
    if (!location) return;
    let alive = true;
    supabase()
      .from("location_stock")
      .select("qty")
      .eq("location_id", location)
      .eq("variant_id", row.id)
      .maybeSingle()
      .then(({ data }) => alive && setCurrent(Number(data?.qty ?? 0)));
    return () => {
      alive = false;
    };
  }, [location, row.id]);

  const base = current ?? 0;
  const n = Number(qty) || 0;
  const change = mode === "add" ? n : mode === "remove" ? -n : n - base;

  const submit = async () => {
    if (change === 0 || !location) return;
    setBusy(true);
    const { error } = await supabase().rpc("adjust_location_stock", {
      p_location: location,
      p_variant: row.id,
      p_qty_change: change,
      p_note: note ? `${reason}: ${note}` : reason,
      p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم تعديل المخزون");
    onDone(change);
  };

  return (
    <Modal
      open
      onClose={onClose}
      title={`تسوية: ${row.product.name} ${variantLabel(row.size, row.color)}`}
      size="sm"
      footer={
        <Button onClick={submit} loading={busy} disabled={change === 0 || current === null}>
          حفظ ({change > 0 ? "+" : ""}
          {change})
        </Button>
      }
    >
      <div className="space-y-3">
        {locations.length > 1 && (
          <Field label="الموقع">
            <Select aria-label="موقع التسوية" value={location} onChange={(e) => (setCurrent(null), setLocation(e.target.value))}>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </Select>
          </Field>
        )}
        <p className="text-sm text-slate-600">
          الكمية الحالية{locations.length > 1 ? " في الموقع" : ""}: <b>{current ?? "…"}</b> ← الجديدة: <b>{base + change}</b>
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
        <p className="text-xs text-slate-500">لا يُسمح بأن يصبح رصيد الموقع سالباً. لنقل بضاعة بين المواقع استخدم التحويلات.</p>
      </div>
    </Modal>
  );
}
