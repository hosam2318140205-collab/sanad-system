// Suppliers, Purchasing & Accounts 2.0: أنواع وتسميات مشتركة
import { supabase } from "@/lib/supabase/client";

export type ApInvoiceStatus = "draft" | "posted" | "partially_paid" | "paid" | "void";
export type ApPaymentTerms = "cash" | "credit" | "partial";
export type ApPaymentMethod = "cash_drawer" | "cash" | "bank_transfer" | "card" | "cheque" | "opening";
export type ApEntryType = "opening" | "invoice" | "payment" | "credit_note" | "refund" | "void_invoice" | "void_payment" | "void_credit_note" | "void_refund";

export interface SupplierInvoice {
  id: string;
  doc_no: string;
  supplier_id: string;
  kind: "opening" | "purchase" | "expense";
  status: ApInvoiceStatus;
  supplier_invoice_no: string | null;
  invoice_date: string;
  due_date: string | null;
  payment_terms: ApPaymentTerms;
  subtotal: number;
  vat_amount: number;
  total: number;
  settled_amount: number;
  notes: string | null;
  purchase_order_id: string | null;
  location_id: string | null;
  match_status: "not_required" | "matched" | "within_tolerance" | "override" | null;
  match_override_reason: string | null;
  created_by: string | null;
  posted_at: string | null;
  void_reason: string | null;
}

export interface MatchLine {
  line_id: string;
  receipt_item_id: string;
  variant_id: string;
  sku: string;
  product_name: string;
  qty_ordered: number;
  qty_received: number;
  qty_invoiced_before: number;
  qty_this: number;
  po_unit_cost: number;
  invoice_unit_cost: number;
  diff_pct: number;
  result: "matched" | "within_tolerance" | "price_over_tolerance" | "qty_over_received";
}

export interface StatementRow {
  entry_id: number | null;
  entry_date: string;
  entry_type: ApEntryType | null;
  ref_no: string | null;
  note: string | null;
  debit: number;
  credit: number;
  balance: number;
  source_id: string | null;
}

export interface AgingRow {
  supplier_id: string;
  supplier_name: string;
  not_due: number;
  d1_30: number;
  d31_60: number;
  d61_90: number;
  d90_plus: number;
  total_open: number;
  unapplied: number;
  net_balance: number;
  ledger_balance: number;
  credit_limit: number | null;
  oldest_due: string | null;
}

export interface OpenDocument {
  invoice_id: string;
  doc_no: string;
  supplier_invoice_no: string | null;
  kind: SupplierInvoice["kind"];
  invoice_date: string;
  due_date: string | null;
  total: number;
  settled: number;
  outstanding: number;
  days_overdue: number;
}

export interface SupplierSuggestion {
  variant_id: string;
  supplier_id: string;
  supplier_name: string;
  cost: number;
  lead_days: number | null;
  fill_rate: number | null;
  score: number;
  reason: string;
  alternatives: Array<{ supplier_id: string; name: string; cost: number | null; lead_days: number | null; score: number | null; sufficient: boolean }>;
}

export const INVOICE_STATUS: Record<ApInvoiceStatus, { label: string; tone: "slate" | "blue" | "amber" | "green" | "red" }> = {
  draft: { label: "مسودة", tone: "slate" },
  posted: { label: "مستحقة", tone: "blue" },
  partially_paid: { label: "مدفوعة جزئياً", tone: "amber" },
  paid: { label: "مدفوعة", tone: "green" },
  void: { label: "ملغاة", tone: "red" },
};

export const TERMS_LABELS: Record<ApPaymentTerms, string> = { cash: "نقدي", credit: "آجل", partial: "جزئي" };

export const METHOD_LABELS: Record<ApPaymentMethod, string> = {
  cash_drawer: "من درج الوردية",
  cash: "نقد (خارج الدرج)",
  bank_transfer: "تحويل بنكي",
  card: "شبكة",
  cheque: "شيك",
  opening: "رصيد افتتاحي",
};

export const ENTRY_LABELS: Record<ApEntryType, string> = {
  opening: "رصيد افتتاحي",
  invoice: "فاتورة",
  payment: "دفعة",
  credit_note: "إشعار دائن",
  refund: "استرداد من المورد",
  void_invoice: "إلغاء فاتورة",
  void_payment: "إلغاء دفعة",
  void_credit_note: "إلغاء إشعار",
  void_refund: "إلغاء استرداد",
};

export const MATCH_LABELS: Record<MatchLine["result"], { label: string; tone: "green" | "amber" | "red" }> = {
  matched: { label: "مطابق", tone: "green" },
  within_tolerance: { label: "فرق ضمن السماح", tone: "amber" },
  price_over_tolerance: { label: "فرق سعر خارج السماح", tone: "red" },
  qty_over_received: { label: "أكثر من المستلم", tone: "red" },
};

export const RETURN_STATUS: Record<string, { label: string; tone: "slate" | "blue" | "violet" | "green" | "red" }> = {
  draft: { label: "مسودة", tone: "slate" },
  approved: { label: "معتمد — بانتظار الشحن", tone: "blue" },
  shipped: { label: "مشحون — بانتظار الإشعار", tone: "violet" },
  credited: { label: "صدر الإشعار", tone: "green" },
  cancelled: { label: "ملغي", tone: "red" },
};

export const CREDIT_KIND_LABELS: Record<string, string> = { return: "مرتجع", price: "تخفيض سعر", rebate: "خصم تجاري" };

export const COST_TYPE_LABELS: Record<string, string> = { freight: "شحن", customs: "جمارك", transport: "نقل داخلي", other: "أخرى" };

/** رفع مرفق إلى المخزن الخاص ثم تسجيله على المستند */
export async function uploadPurchaseAttachment(ownerType: string, ownerId: string, file: File): Promise<void> {
  const safe = file.name.replace(/[^\w.\-]+/g, "_").slice(-80);
  const path = `${ownerType}/${ownerId}/${crypto.randomUUID()}-${safe}`;
  const db = supabase();
  const { error: upErr } = await db.storage.from("purchase-docs").upload(path, file, { contentType: file.type, upsert: false });
  if (upErr) throw upErr;
  const { error } = await db.rpc("add_purchase_attachment", {
    p_owner_type: ownerType,
    p_owner_id: ownerId,
    p_path: path,
    p_name: file.name,
    p_mime: file.type,
    p_size: file.size,
  });
  if (error) throw error;
}

export async function openPurchaseAttachment(path: string): Promise<void> {
  const { data, error } = await supabase().storage.from("purchase-docs").createSignedUrl(path, 120);
  if (error) throw error;
  window.open(data.signedUrl, "_blank", "noopener");
}
