import type { ReceiptData } from "@/components/receipt";
import { supabase } from "./supabase/client";
import type { Sale, SaleItem, SalePayment } from "./types";

export const SALE_ITEM_COLUMNS =
  "id, sale_id, variant_id, product_name, variant_label, sku, qty, unit_price, line_discount, line_total, vat_amount, returned_qty";

/** Loads everything the thermal receipt needs. */
export async function loadReceipt(saleId: string): Promise<ReceiptData> {
  const db = supabase();
  const [{ data: sale, error }, { data: items }, { data: payments }] = await Promise.all([
    db
      .from("sales")
      .select("*, customer:customers(name, vat_number), cashier:profiles(full_name)")
      .eq("id", saleId)
      .single(),
    db.from("sale_items").select(SALE_ITEM_COLUMNS).eq("sale_id", saleId),
    db.from("sale_payments").select("id, sale_id, method, amount, reference").eq("sale_id", saleId),
  ]);
  if (error || !sale) throw error ?? new Error("الفاتورة غير موجودة");
  const s = sale as Sale & {
    customer: { name: string; vat_number: string | null } | null;
    cashier: { full_name: string } | null;
  };
  return {
    sale: s,
    items: (items ?? []) as SaleItem[],
    payments: (payments ?? []) as SalePayment[],
    cashierName: s.cashier?.full_name,
    customerName: s.customer?.name,
    customerVat: s.customer?.vat_number,
  };
}

/** Prints the element marked .print-area (thermal receipt, labels...). */
export function printNow() {
  setTimeout(() => window.print(), 50);
}
