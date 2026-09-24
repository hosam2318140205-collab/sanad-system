"use client";

import { ArrowRight, ImagePlus, Printer, Sparkles, Trash2, Wand2 } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { BarcodeLabels, type LabelItem } from "@/components/barcode-labels";
import { PrintPortal } from "@/components/print-portal";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, Checkbox, Field, Input, Loading, Modal, PageHeader, Select, Table, Textarea, useToast } from "@/components/ui";
import { generateEan13, makeSku } from "@/lib/barcode";
import { errorMessage, variantLabel } from "@/lib/format";
import { printNow } from "@/lib/sales";
import { supabase } from "@/lib/supabase/client";
import type { Category, Product, Variant } from "@/lib/types";

interface VariantRow {
  key: string;
  id: string | null;
  size: string;
  color: string;
  color_hex: string;
  sku: string;
  barcode: string;
  price: string;
  cost: string;
  opening: string;
  low: string;
  is_active: boolean;
  stock_qty: number;
  deleted: boolean;
}

const SIZE_PRESETS: Record<string, string[]> = {
  "ملابس (حروف)": ["XS", "S", "M", "L", "XL", "XXL", "3XL"],
  "ثياب رجالي": ["50", "52", "54", "56", "58", "60", "62"],
  "بناطيل": ["28", "30", "32", "34", "36", "38", "40"],
  "أحذية": ["39", "40", "41", "42", "43", "44", "45"],
  "أطفال (سنوات)": ["2", "4", "6", "8", "10", "12", "14"],
  "مقاس واحد": ["فري سايز"],
};

const COLOR_PRESETS: Array<{ name: string; hex: string }> = [
  { name: "أبيض", hex: "#ffffff" },
  { name: "أسود", hex: "#111111" },
  { name: "كحلي", hex: "#1e2a4a" },
  { name: "رمادي", hex: "#8a8f98" },
  { name: "بيج", hex: "#d9c7a7" },
  { name: "بني", hex: "#6b4226" },
  { name: "أحمر", hex: "#c0392b" },
  { name: "أزرق", hex: "#2e86de" },
  { name: "أخضر", hex: "#27ae60" },
  { name: "عودي", hex: "#5a2e2e" },
];

const emptyProduct = {
  name: "",
  name_en: "",
  category_id: "",
  brand: "",
  description: "",
  base_price: "",
  default_cost: "",
  is_active: true,
  image_url: null as string | null,
};

let keySeq = 0;
const newKey = () => `k${++keySeq}`;

export function ProductForm({ productId }: { productId: string | null }) {
  const router = useRouter();
  const toast = useToast();
  const { isOwner, settings } = useSession();
  const [loading, setLoading] = useState(!!productId);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState(emptyProduct);
  const [categories, setCategories] = useState<Category[]>([]);
  const [rows, setRows] = useState<VariantRow[]>([]);
  const [imageFile, setImageFile] = useState<File | null>(null);
  const [imagePreview, setImagePreview] = useState<string | null>(null);
  const [sizesInput, setSizesInput] = useState("");
  const [colors, setColors] = useState<Array<{ name: string; hex: string }>>([]);
  const [colorName, setColorName] = useState("");
  const [colorHex, setColorHex] = useState("#000000");
  const [labels, setLabels] = useState<LabelItem[] | null>(null);
  const [labelsOpen, setLabelsOpen] = useState(false);

  useEffect(() => {
    const db = supabase();
    db.from("categories")
      .select("*")
      .order("sort_order")
      .then(({ data }) => setCategories((data ?? []) as Category[]));
    if (!productId) return;
    (async () => {
      const [{ data: p, error }, { data: vs }] = await Promise.all([
        db.from("products").select("*").eq("id", productId).single(),
        db.from("product_variants").select("*").eq("product_id", productId).order("created_at"),
      ]);
      if (error || !p) {
        toast("المنتج غير موجود", "error");
        router.replace("/products");
        return;
      }
      const product = p as Product;
      const variants = (vs ?? []) as Variant[];
      const { data: costs } = await db
        .from("variant_costs")
        .select("variant_id, cost_price")
        .in(
          "variant_id",
          variants.map((v) => v.id),
        );
      const costMap = new Map((costs ?? []).map((c: { variant_id: string; cost_price: number }) => [c.variant_id, c.cost_price]));
      setForm({
        name: product.name,
        name_en: product.name_en ?? "",
        category_id: product.category_id ?? "",
        brand: product.brand ?? "",
        description: product.description ?? "",
        base_price: String(product.base_price),
        default_cost: "",
        is_active: product.is_active,
        image_url: product.image_url,
      });
      setRows(
        variants.map((v) => ({
          key: newKey(),
          id: v.id,
          size: v.size ?? "",
          color: v.color ?? "",
          color_hex: v.color_hex ?? "",
          sku: v.sku,
          barcode: v.barcode ?? "",
          price: v.price === null ? "" : String(v.price),
          cost: String(costMap.get(v.id) ?? 0),
          opening: "0",
          low: String(v.low_stock_threshold),
          is_active: v.is_active,
          stock_qty: v.stock_qty,
          deleted: false,
        })),
      );
      setLoading(false);
    })();
  }, [productId, router, toast]);

  const set = <K extends keyof typeof form>(k: K, v: (typeof form)[K]) => setForm((f) => ({ ...f, [k]: v }));
  const setRow = (key: string, patch: Partial<VariantRow>) =>
    setRows((rs) => rs.map((r) => (r.key === key ? { ...r, ...patch } : r)));

  const sizes = sizesInput
    .split(/[,،\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);

  const generate = () => {
    const sizeList = sizes.length ? sizes : [""];
    const colorList = colors.length ? colors : [{ name: "", hex: "" }];
    const existing = new Set(rows.filter((r) => !r.deleted).map((r) => `${r.size}|${r.color}`));
    const added: VariantRow[] = [];
    let seq = rows.length;
    for (const c of colorList) {
      for (const s of sizeList) {
        if (existing.has(`${s}|${c.name}`)) continue;
        seq++;
        added.push({
          key: newKey(),
          id: null,
          size: s,
          color: c.name,
          color_hex: c.hex,
          sku: makeSku(form.name_en || form.name, s || null, c.name || null, seq),
          barcode: generateEan13(),
          price: "",
          cost: form.default_cost || "0",
          opening: "0",
          low: "3",
          is_active: true,
          stock_qty: 0,
          deleted: false,
        });
      }
    }
    if (added.length === 0) toast("كل التركيبات موجودة مسبقاً", "info");
    // SKU فريد داخل المنتج
    const used = new Set(rows.map((r) => r.sku));
    for (const a of added) {
      let sku = a.sku;
      let n = 2;
      while (used.has(sku)) sku = `${a.sku}-${n++}`;
      a.sku = sku;
      used.add(sku);
    }
    setRows((r) => [...r, ...added]);
  };

  const addColor = (name: string, hex: string) => {
    if (!name.trim() || colors.some((c) => c.name === name.trim())) return;
    setColors((c) => [...c, { name: name.trim(), hex }]);
    setColorName("");
  };

  const onImage = (file: File | null) => {
    setImageFile(file);
    setImagePreview(file ? URL.createObjectURL(file) : null);
  };

  const save = async () => {
    const active = rows.filter((r) => !r.deleted);
    if (!form.name.trim()) return toast("اسم المنتج مطلوب", "error");
    if (form.base_price === "" || Number(form.base_price) < 0) return toast("السعر مطلوب", "error");
    if (active.length === 0) return toast("أضف مقاساً/لوناً واحداً على الأقل", "error");
    const combos = new Set<string>();
    for (const r of active) {
      if (!r.sku.trim()) return toast("رمز SKU مطلوب لكل صنف", "error");
      const k = `${r.size}|${r.color}`;
      if (combos.has(k)) return toast(`التركيبة ${variantLabel(r.size, r.color)} مكررة`, "error");
      combos.add(k);
    }

    setSaving(true);
    const db = supabase();
    try {
      const payload = {
        name: form.name.trim(),
        name_en: form.name_en.trim() || null,
        category_id: form.category_id || null,
        brand: form.brand.trim() || null,
        description: form.description.trim() || null,
        base_price: Number(form.base_price),
        is_active: form.is_active,
      };
      let id = productId;
      if (id) {
        const { error } = await db.from("products").update(payload).eq("id", id);
        if (error) throw error;
      } else {
        const { data, error } = await db.from("products").insert(payload).select("id").single();
        if (error) throw error;
        id = (data as { id: string }).id;
      }

      if (imageFile) {
        const ext = imageFile.name.split(".").pop()?.toLowerCase() || "jpg";
        const path = `products/${id}-${Date.now()}.${ext}`;
        const { error: upErr } = await db.storage.from("product-images").upload(path, imageFile, { upsert: true, contentType: imageFile.type });
        if (upErr) throw upErr;
        const { data: pub } = db.storage.from("product-images").getPublicUrl(path);
        const { error } = await db.from("products").update({ image_url: pub.publicUrl }).eq("id", id);
        if (error) throw error;
      }

      // حذف الأصناف المحذوفة (المالك فقط)
      for (const r of rows.filter((x) => x.deleted && x.id)) {
        const { error } = await db.from("product_variants").delete().eq("id", r.id!);
        if (error) throw new Error(`لا يمكن حذف ${r.sku} لوجود حركات عليه — قم بإيقافه بدلاً من ذلك`);
      }

      const costs: Array<{ variant_id: string; cost_price: number }> = [];
      for (const r of active) {
        const base = {
          sku: r.sku.trim(),
          barcode: r.barcode.trim() || null,
          size: r.size.trim() || null,
          color: r.color.trim() || null,
          color_hex: r.color_hex || null,
          price: r.price === "" ? null : Number(r.price),
          low_stock_threshold: Number(r.low) || 0,
          is_active: r.is_active,
        };
        if (r.id) {
          const { error } = await db.from("product_variants").update(base).eq("id", r.id);
          if (error) throw error;
          costs.push({ variant_id: r.id, cost_price: Number(r.cost) || 0 });
        } else {
          const { data, error } = await db
            .from("product_variants")
            .insert({ ...base, product_id: id, stock_qty: Number(r.opening) || 0 })
            .select("id")
            .single();
          if (error) throw error;
          costs.push({ variant_id: (data as { id: string }).id, cost_price: Number(r.cost) || 0 });
        }
      }
      if (costs.length) {
        const { error } = await db.from("variant_costs").upsert(costs, { onConflict: "variant_id" });
        if (error) throw error;
      }

      toast("تم حفظ المنتج");
      router.push("/products");
      router.refresh();
    } catch (e) {
      toast(errorMessage(e), "error");
      setSaving(false);
    }
  };

  const toggleProductActive = () => set("is_active", !form.is_active);

  const openLabels = () => {
    setLabels(
      rows
        .filter((r) => !r.deleted && r.id && (r.barcode || r.sku))
        .map((r) => ({
          key: r.key,
          name: form.name,
          variant: variantLabel(r.size, r.color),
          price: Number(r.price || form.base_price),
          code: r.barcode || r.sku,
          copies: Math.max(r.stock_qty, 1),
        })),
    );
    setLabelsOpen(true);
  };

  if (loading) return <Loading />;

  const visibleRows = rows.filter((r) => !r.deleted);
  const margin = (r: VariantRow) => {
    const price = Number(r.price || form.base_price);
    const cost = Number(r.cost);
    if (!price || !cost) return null;
    const net = settings.prices_include_vat ? price / (1 + Number(settings.vat_rate) / 100) : price;
    return ((net - cost) / net) * 100;
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={productId ? "تعديل المنتج" : "منتج جديد"}
        actions={
          <>
            <Link href="/products">
              <Button variant="ghost">
                <ArrowRight className="size-4" /> رجوع
              </Button>
            </Link>
            {productId && (
              <Button variant="outline" onClick={openLabels}>
                <Printer className="size-4" /> ملصقات الباركود
              </Button>
            )}
            <Button onClick={save} loading={saving}>
              حفظ
            </Button>
          </>
        }
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="space-y-4 p-4 lg:col-span-2">
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="اسم المنتج *">
              <Input value={form.name} onChange={(e) => set("name", e.target.value)} placeholder="ثوب سعودي قطن" />
            </Field>
            <Field label="الاسم بالإنجليزية" hint="يُستخدم لتوليد رموز SKU">
              <Input dir="ltr" value={form.name_en} onChange={(e) => set("name_en", e.target.value)} placeholder="Cotton Thobe" />
            </Field>
            <Field label="التصنيف">
              <Select value={form.category_id} onChange={(e) => set("category_id", e.target.value)}>
                <option value="">بدون تصنيف</option>
                {categories.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </Select>
            </Field>
            <Field label="الماركة">
              <Input value={form.brand} onChange={(e) => set("brand", e.target.value)} />
            </Field>
            <Field label={`سعر البيع * ${settings.prices_include_vat ? "(شامل الضريبة)" : "(غير شامل الضريبة)"}`}>
              <Input type="number" step="0.01" min={0} value={form.base_price} onChange={(e) => set("base_price", e.target.value)} />
            </Field>
            {!productId && (
              <Field label="تكلفة الشراء الافتراضية (قبل الضريبة)" hint="تُطبق على المقاسات المولدة">
                <Input type="number" step="0.01" min={0} value={form.default_cost} onChange={(e) => set("default_cost", e.target.value)} />
              </Field>
            )}
          </div>
          <Field label="الوصف">
            <Textarea value={form.description} onChange={(e) => set("description", e.target.value)} />
          </Field>
          <Checkbox label="المنتج نشط ويظهر في نقطة البيع" checked={form.is_active} onChange={toggleProductActive} />
        </Card>

        <Card className="p-4">
          <p className="mb-2 text-sm font-medium text-slate-700">صورة المنتج</p>
          <label className="flex aspect-square cursor-pointer flex-col items-center justify-center overflow-hidden rounded-xl border-2 border-dashed border-slate-300 bg-slate-50 text-slate-500 hover:border-brand-600">
            {imagePreview || form.image_url ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={imagePreview ?? form.image_url ?? ""} alt="" className="size-full object-cover" />
            ) : (
              <>
                <ImagePlus className="mb-2 size-10" />
                <span className="text-sm">اضغط لرفع صورة أو التقاطها</span>
              </>
            )}
            <input type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => onImage(e.target.files?.[0] ?? null)} />
          </label>
        </Card>
      </div>

      {/* مولد المقاسات والألوان */}
      <Card className="mt-4 space-y-4 p-4">
        <div className="flex items-center gap-2">
          <Wand2 className="size-5 text-brand-700" />
          <h2 className="font-semibold">المقاسات والألوان</h2>
          <span className="text-sm text-slate-500">— كل تركيبة (مقاس × لون) لها مخزون وباركود مستقل</span>
        </div>
        <div className="grid gap-4 md:grid-cols-2">
          <div className="space-y-2">
            <Field label="المقاسات" hint="افصل بفاصلة أو مسافة">
              <Input value={sizesInput} onChange={(e) => setSizesInput(e.target.value)} placeholder="S, M, L, XL" dir="ltr" />
            </Field>
            <div className="flex flex-wrap gap-1.5">
              {Object.entries(SIZE_PRESETS).map(([label, list]) => (
                <button key={label} className="rounded-full bg-slate-100 px-2.5 py-1 text-xs hover:bg-slate-200" onClick={() => setSizesInput(list.join(", "))}>
                  {label}
                </button>
              ))}
            </div>
          </div>
          <div className="space-y-2">
            <p className="text-sm font-medium text-slate-700">الألوان</p>
            <div className="flex gap-2">
              <Input value={colorName} onChange={(e) => setColorName(e.target.value)} placeholder="اسم اللون" onKeyDown={(e) => e.key === "Enter" && addColor(colorName, colorHex)} />
              <input type="color" value={colorHex} onChange={(e) => setColorHex(e.target.value)} className="h-10 w-12 cursor-pointer rounded-lg border border-slate-300" aria-label="اختيار اللون" />
              <Button variant="outline" onClick={() => addColor(colorName, colorHex)}>
                إضافة
              </Button>
            </div>
            <div className="flex flex-wrap gap-1.5">
              {COLOR_PRESETS.map((c) => (
                <button
                  key={c.name}
                  onClick={() => addColor(c.name, c.hex)}
                  className="flex items-center gap-1 rounded-full bg-slate-100 px-2 py-1 text-xs hover:bg-slate-200"
                >
                  <span className="size-3 rounded-full border border-slate-300" style={{ background: c.hex }} />
                  {c.name}
                </button>
              ))}
            </div>
            {colors.length > 0 && (
              <div className="flex flex-wrap gap-1.5">
                {colors.map((c) => (
                  <span key={c.name} className="flex items-center gap-1 rounded-full bg-brand-50 px-2.5 py-1 text-xs text-brand-800 ring-1 ring-brand-200">
                    <span className="size-3 rounded-full border border-slate-300" style={{ background: c.hex }} />
                    {c.name}
                    <button onClick={() => setColors(colors.filter((x) => x.name !== c.name))} className="ms-1 text-slate-500 hover:text-red-600">
                      ×
                    </button>
                  </span>
                ))}
              </div>
            )}
          </div>
        </div>
        <Button variant="secondary" onClick={generate} disabled={!form.name.trim()}>
          <Sparkles className="size-4" /> توليد التركيبات ({Math.max(sizes.length, 1) * Math.max(colors.length, 1)})
        </Button>

        {visibleRows.length > 0 && (
          <Table className="rounded-lg border border-slate-200">
            <thead>
              <tr>
                <th>المقاس</th>
                <th>اللون</th>
                <th>SKU</th>
                <th>الباركود</th>
                <th>سعر خاص</th>
                <th>التكلفة</th>
                <th>{productId ? "المخزون" : "رصيد افتتاحي"}</th>
                <th>حد التنبيه</th>
                <th>نشط</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {visibleRows.map((r) => {
                const m = margin(r);
                return (
                  <tr key={r.key}>
                    <td>
                      <Input className="h-9 w-20" value={r.size} onChange={(e) => setRow(r.key, { size: e.target.value })} />
                    </td>
                    <td>
                      <div className="flex items-center gap-1">
                        {r.color_hex && <span className="size-4 shrink-0 rounded-full border" style={{ background: r.color_hex }} />}
                        <Input className="h-9 w-24" value={r.color} onChange={(e) => setRow(r.key, { color: e.target.value })} />
                      </div>
                    </td>
                    <td>
                      <Input dir="ltr" className="h-9 w-36" value={r.sku} onChange={(e) => setRow(r.key, { sku: e.target.value })} />
                    </td>
                    <td>
                      <div className="flex items-center gap-1">
                        <Input dir="ltr" className="h-9 w-36" value={r.barcode} onChange={(e) => setRow(r.key, { barcode: e.target.value })} />
                        <button className="text-xs text-brand-700 hover:underline" onClick={() => setRow(r.key, { barcode: generateEan13() })} title="توليد باركود">
                          توليد
                        </button>
                      </div>
                    </td>
                    <td>
                      <Input type="number" step="0.01" className="h-9 w-24" placeholder={form.base_price || "-"} value={r.price} onChange={(e) => setRow(r.key, { price: e.target.value })} />
                    </td>
                    <td>
                      <Input type="number" step="0.01" className="h-9 w-24" value={r.cost} onChange={(e) => setRow(r.key, { cost: e.target.value })} />
                      {m !== null && <div className={`mt-0.5 text-xs ${m < 0 ? "text-red-600" : "text-slate-500"}`}>هامش {m.toFixed(0)}%</div>}
                    </td>
                    <td>
                      {r.id ? (
                        <Badge tone={r.stock_qty <= Number(r.low) ? "amber" : "slate"}>{r.stock_qty}</Badge>
                      ) : (
                        <Input type="number" min={0} className="h-9 w-20" value={r.opening} onChange={(e) => setRow(r.key, { opening: e.target.value })} />
                      )}
                    </td>
                    <td>
                      <Input type="number" min={0} className="h-9 w-16" value={r.low} onChange={(e) => setRow(r.key, { low: e.target.value })} />
                    </td>
                    <td>
                      <input type="checkbox" className="size-4 accent-brand-700" checked={r.is_active} onChange={(e) => setRow(r.key, { is_active: e.target.checked })} />
                    </td>
                    <td>
                      {(!r.id || isOwner) && (
                        <button
                          className="p-1.5 text-slate-400 hover:text-red-600"
                          onClick={() => (r.id ? setRow(r.key, { deleted: true }) : setRows((rs) => rs.filter((x) => x.key !== r.key)))}
                          aria-label="حذف"
                        >
                          <Trash2 className="size-4" />
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
        {productId && (
          <p className="text-xs text-slate-500">
            لتعديل كميات الأصناف الحالية استخدم صفحة المخزون (تسوية) أو الجرد — كل تغيير يُسجل في حركات المخزون.
          </p>
        )}
      </Card>

      <Modal
        open={labelsOpen}
        onClose={() => setLabelsOpen(false)}
        title="طباعة ملصقات الباركود (50×30mm)"
        footer={
          <Button onClick={printNow}>
            <Printer className="size-4" /> طباعة
          </Button>
        }
      >
        <ul className="divide-y divide-slate-100">
          {labels?.map((l, i) => (
            <li key={l.key} className="flex items-center gap-3 py-2">
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium">{l.variant || l.name}</p>
                <p className="ltr-nums text-xs text-slate-500">{l.code}</p>
              </div>
              <span className="text-xs text-slate-500">النسخ</span>
              <Input
                type="number"
                min={0}
                className="h-9 w-20"
                value={l.copies}
                onChange={(e) => setLabels((ls) => ls!.map((x, idx) => (idx === i ? { ...x, copies: Number(e.target.value) || 0 } : x)))}
              />
            </li>
          ))}
        </ul>
        {labels?.length === 0 && <p className="py-6 text-center text-sm text-slate-500">احفظ الأصناف أولاً</p>}
      </Modal>
      {labelsOpen && labels && (
        <PrintPortal>
          <BarcodeLabels items={labels} storeName={settings.store_name} />
        </PrintPortal>
      )}
    </div>
  );
}
