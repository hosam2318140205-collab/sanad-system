"use client";

import { Plus, Search, Tags, Trash2 } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, ConfirmDialog, EmptyState, Input, Loading, Modal, PageHeader, Select, Table, useToast } from "@/components/ui";
import { normalize } from "@/lib/catalog";
import { errorMessage, money, num } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Category, ProductWithVariants } from "@/lib/types";

export function ProductsList() {
  const toast = useToast();
  const [products, setProducts] = useState<ProductWithVariants[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState("");
  const [cat, setCat] = useState("");
  const [status, setStatus] = useState<"all" | "active" | "inactive" | "low">("active");
  const [showCats, setShowCats] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    const db = supabase();
    const [{ data, error }, { data: cats }] = await Promise.all([
      db
        .from("products")
        .select("*, category:categories(name), variants:product_variants(*)")
        .order("created_at", { ascending: false }),
      db.from("categories").select("*").order("sort_order").order("name"),
    ]);
    if (error) toast(errorMessage(error), "error");
    setProducts((data ?? []) as ProductWithVariants[]);
    setCategories((cats ?? []) as Category[]);
    setLoading(false);
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const filtered = useMemo(() => {
    const term = normalize(q);
    return products.filter((p) => {
      if (cat && p.category_id !== cat) return false;
      if (status === "active" && !p.is_active) return false;
      if (status === "inactive" && p.is_active) return false;
      if (status === "low" && !p.variants.some((v) => v.is_active && v.stock_qty <= v.low_stock_threshold)) return false;
      if (!term) return true;
      return (
        normalize(p.name).includes(term) ||
        (p.brand && normalize(p.brand).includes(term)) ||
        p.variants.some((v) => v.sku.toLowerCase().includes(term) || v.barcode?.includes(term))
      );
    });
  }, [products, q, cat, status]);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="المنتجات"
        subtitle={`${num(products.length)} منتج · ${num(products.reduce((s, p) => s + p.variants.length, 0))} صنف (مقاس/لون)`}
        actions={
          <>
            <Button variant="outline" onClick={() => setShowCats(true)}>
              <Tags className="size-4" /> التصنيفات
            </Button>
            <Link href="/products/new">
              <Button>
                <Plus className="size-4" /> منتج جديد
              </Button>
            </Link>
          </>
        }
      />

      <Card>
        <div className="flex flex-wrap gap-2 border-b border-slate-100 p-3">
          <div className="relative min-w-52 flex-1">
            <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <Input className="ps-9" placeholder="بحث بالاسم، الماركة، SKU أو الباركود" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
          <Select className="w-auto" value={cat} onChange={(e) => setCat(e.target.value)}>
            <option value="">كل التصنيفات</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
          <Select className="w-auto" value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
            <option value="active">النشطة</option>
            <option value="inactive">الموقوفة</option>
            <option value="low">مخزون منخفض</option>
            <option value="all">الكل</option>
          </Select>
        </div>

        {loading ? (
          <Loading />
        ) : filtered.length === 0 ? (
          <EmptyState title="لا توجد منتجات">
            <Link href="/products/new" className="text-sm text-brand-700 hover:underline">
              أضف أول منتج
            </Link>
          </EmptyState>
        ) : (
          <Table>
            <thead>
              <tr>
                <th>المنتج</th>
                <th>التصنيف</th>
                <th>السعر</th>
                <th>المقاسات / الألوان</th>
                <th>المخزون</th>
                <th>الحالة</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((p) => {
                const stock = p.variants.reduce((s, v) => s + v.stock_qty, 0);
                const low = p.variants.filter((v) => v.is_active && v.stock_qty <= v.low_stock_threshold).length;
                const sizes = [...new Set(p.variants.map((v) => v.size).filter(Boolean))];
                const colors = [...new Set(p.variants.map((v) => v.color).filter(Boolean))];
                return (
                  <tr key={p.id}>
                    <td>
                      <Link href={`/products/${p.id}`} className="flex items-center gap-3 hover:text-brand-700">
                        <div className="size-11 shrink-0 overflow-hidden rounded-lg bg-slate-100">
                          {p.image_url && (
                            // eslint-disable-next-line @next/next/no-img-element
                            <img src={p.image_url} alt="" className="size-full object-cover" />
                          )}
                        </div>
                        <div>
                          <p className="font-medium">{p.name}</p>
                          {p.brand && <p className="text-xs text-slate-500">{p.brand}</p>}
                        </div>
                      </Link>
                    </td>
                    <td>{p.category?.name ?? "-"}</td>
                    <td className="font-medium">{money(p.base_price)}</td>
                    <td className="max-w-64 text-xs text-slate-600">
                      <div className="truncate">{sizes.join("، ") || "-"}</div>
                      <div className="truncate text-slate-400">{colors.join("، ")}</div>
                    </td>
                    <td>
                      <span className={stock <= 0 ? "font-semibold text-red-600" : "font-semibold"}>{num(stock)}</span>
                      {low > 0 && (
                        <span className="ms-2">
                          <Badge tone="amber">{low} منخفض</Badge>
                        </span>
                      )}
                    </td>
                    <td>{p.is_active ? <Badge tone="green">نشط</Badge> : <Badge>موقوف</Badge>}</td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>

      <CategoriesModal open={showCats} onClose={() => setShowCats(false)} categories={categories} onChanged={load} />
    </div>
  );
}

function CategoriesModal({
  open,
  onClose,
  categories,
  onChanged,
}: {
  open: boolean;
  onClose: () => void;
  categories: Category[];
  onChanged: () => void;
}) {
  const toast = useToast();
  const { isOwner, isManager } = useSession();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [toDelete, setToDelete] = useState<Category | null>(null);

  const add = async () => {
    if (!name.trim()) return;
    setBusy(true);
    const { error } = await supabase()
      .from("categories")
      .insert({ name: name.trim(), sort_order: categories.length + 1 });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    setName("");
    onChanged();
  };

  const rename = async (c: Category, newName: string) => {
    if (!newName.trim() || newName === c.name) return;
    const { error } = await supabase().from("categories").update({ name: newName.trim() }).eq("id", c.id);
    if (error) toast(errorMessage(error), "error");
    else onChanged();
  };

  const remove = async () => {
    if (!toDelete) return;
    const { error } = await supabase().from("categories").delete().eq("id", toDelete.id);
    setToDelete(null);
    if (error) toast(errorMessage(error), "error");
    else onChanged();
  };

  return (
    <Modal open={open} onClose={onClose} title="التصنيفات">
      <div className="space-y-3">
        <div className="flex gap-2">
          <Input placeholder="تصنيف جديد (مثال: ثياب، عبايات، أحذية)" value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add()} />
          <Button onClick={add} loading={busy} disabled={!isManager}>
            إضافة
          </Button>
        </div>
        <ul className="divide-y divide-slate-100">
          {categories.map((c) => (
            <li key={c.id} className="flex items-center gap-2 py-2">
              <Input defaultValue={c.name} onBlur={(e) => rename(c, e.target.value)} className="h-9" />
              {isOwner && (
                <button className="p-2 text-slate-400 hover:text-red-600" onClick={() => setToDelete(c)} aria-label="حذف">
                  <Trash2 className="size-4" />
                </button>
              )}
            </li>
          ))}
        </ul>
      </div>
      <ConfirmDialog
        open={!!toDelete}
        title="حذف التصنيف"
        message={`سيتم حذف "${toDelete?.name}" وتبقى منتجاته بدون تصنيف.`}
        tone="danger"
        confirmLabel="حذف"
        onConfirm={remove}
        onClose={() => setToDelete(null)}
      />
    </Modal>
  );
}
