import { supabase } from "./supabase/client";
import type { CatalogItem, Category } from "./types";

const PAGE = 1000;

interface VariantRow {
  id: string;
  product_id: string;
  sku: string;
  barcode: string | null;
  size: string | null;
  color: string | null;
  color_hex: string | null;
  price: number | null;
  stock_qty: number;
  product: { id: string; name: string; image_url: string | null; category_id: string | null; base_price: number };
}

/** All active, sellable variants flattened for fast in-memory search on the POS. */
export async function fetchCatalog(): Promise<CatalogItem[]> {
  const db = supabase();
  const out: CatalogItem[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await db
      .from("product_variants")
      .select(
        "id, product_id, sku, barcode, size, color, color_hex, price, stock_qty, product:products!inner(id, name, image_url, category_id, base_price)",
      )
      .eq("is_active", true)
      .eq("product.is_active", true)
      .order("product_id")
      .order("sku")
      .range(from, from + PAGE - 1);
    if (error) throw error;
    const rows = (data ?? []) as unknown as VariantRow[];
    for (const v of rows) {
      out.push({
        variant_id: v.id,
        product_id: v.product_id,
        product_name: v.product.name,
        image_url: v.product.image_url,
        category_id: v.product.category_id,
        sku: v.sku,
        barcode: v.barcode,
        size: v.size,
        color: v.color,
        color_hex: v.color_hex,
        price: Number(v.price ?? v.product.base_price),
        stock_qty: v.stock_qty,
      });
    }
    if (rows.length < PAGE) break;
  }
  return out;
}

export async function fetchCategories(): Promise<Category[]> {
  const { data } = await supabase().from("categories").select("*").order("sort_order").order("name");
  return (data ?? []) as Category[];
}

/** Arabic-friendly normalization for search (أ/إ/آ → ا, ة → ه, ى → ي). */
export function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[أإآ]/g, "ا")
    .replace(/ة/g, "ه")
    .replace(/ى/g, "ي")
    .replace(/[ً-ْ]/g, "")
    .trim();
}

/** Pages through a PostgREST query (Supabase caps responses at 1000 rows). */
export async function fetchAllRows<T>(
  page: (from: number, to: number) => PromiseLike<{ data: unknown[] | null; error: { message: string } | null }>,
  pageSize = 1000,
): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await page(from, from + pageSize - 1);
    if (error) throw error;
    out.push(...((data ?? []) as T[]));
    if (!data || data.length < pageSize) break;
  }
  return out;
}
