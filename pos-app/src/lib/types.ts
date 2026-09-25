export type UserRole = "owner" | "manager" | "cashier";
export type PaymentMethod = "cash" | "card" | "transfer" | "exchange_credit";
export type RefundMethod = "cash" | "card" | "transfer" | "exchange";
export type SaleStatus = "completed" | "partially_returned" | "returned";
export type PurchaseStatus = "draft" | "ordered" | "received" | "cancelled";
export type MovementType = "opening" | "sale" | "return" | "purchase" | "adjustment" | "count";
export type CountStatus = "open" | "applied" | "cancelled";

export interface Profile {
  id: string;
  full_name: string;
  email: string | null;
  phone: string | null;
  role: UserRole;
  is_active: boolean;
  created_at: string;
}

export interface StoreSettings {
  id: number;
  store_name: string;
  store_name_en: string | null;
  vat_number: string | null;
  cr_number: string | null;
  phone: string | null;
  address: string | null;
  logo_url: string | null;
  receipt_footer: string | null;
  vat_rate: number;
  prices_include_vat: boolean;
  allow_negative_stock: boolean;
  allow_cashier_returns: boolean;
  max_cashier_discount_pct: number;
  return_days: number;
  currency: string;
  require_shift: boolean;
}

export interface Category {
  id: string;
  name: string;
  sort_order: number;
}

export interface Product {
  id: string;
  name: string;
  name_en: string | null;
  category_id: string | null;
  brand: string | null;
  description: string | null;
  image_url: string | null;
  base_price: number;
  is_active: boolean;
  created_at: string;
}

export interface Variant {
  id: string;
  product_id: string;
  sku: string;
  barcode: string | null;
  size: string | null;
  color: string | null;
  color_hex: string | null;
  price: number | null;
  stock_qty: number;
  low_stock_threshold: number;
  is_active: boolean;
}

export interface ProductWithVariants extends Product {
  variants: Variant[];
  category?: { name: string } | null;
}

export interface Customer {
  id: string;
  name: string;
  phone: string | null;
  email: string | null;
  vat_number: string | null;
  city: string | null;
  notes: string | null;
  created_at: string;
}

export interface Supplier {
  id: string;
  name: string;
  contact_name: string | null;
  phone: string | null;
  email: string | null;
  vat_number: string | null;
  address: string | null;
  notes: string | null;
  is_active: boolean;
}

export interface Sale {
  id: string;
  invoice_no: string;
  customer_id: string | null;
  cashier_id: string;
  subtotal: number;
  discount_total: number;
  invoice_discount: number;
  vat_rate: number;
  vat_amount: number;
  total: number;
  paid_amount: number;
  change_amount: number;
  returned_amount: number;
  status: SaleStatus;
  notes: string | null;
  created_at: string;
}

export interface SaleItem {
  id: string;
  sale_id: string;
  variant_id: string;
  product_name: string;
  variant_label: string | null;
  sku: string | null;
  qty: number;
  unit_price: number;
  line_discount: number;
  line_total: number;
  vat_amount: number;
  returned_qty: number;
}

export interface SalePayment {
  id: string;
  sale_id: string;
  method: PaymentMethod;
  amount: number;
  reference: string | null;
}

export interface ReturnRecord {
  id: string;
  return_no: string;
  sale_id: string;
  cashier_id: string;
  refund_method: RefundMethod;
  total: number;
  vat_amount: number;
  reason: string | null;
  credit_used_by_sale: string | null;
  created_at: string;
}

export interface PurchaseOrder {
  id: string;
  po_no: string;
  supplier_id: string;
  status: PurchaseStatus;
  supplier_invoice_no: string | null;
  subtotal: number;
  vat_amount: number;
  total: number;
  notes: string | null;
  received_at: string | null;
  created_at: string;
}

export interface PurchaseItem {
  id: string;
  purchase_id: string;
  variant_id: string;
  qty: number;
  unit_cost: number;
}

export interface StockCount {
  id: string;
  count_no: string;
  status: CountStatus;
  category_id: string | null;
  notes: string | null;
  applied_at: string | null;
  created_at: string;
}

export interface StockCountItem {
  id: string;
  count_id: string;
  variant_id: string;
  expected_qty: number;
  counted_qty: number | null;
}

export interface StockMovement {
  id: number;
  variant_id: string;
  type: MovementType;
  qty_change: number;
  balance_after: number;
  ref_id: string | null;
  note: string | null;
  created_by: string | null;
  created_at: string;
}

export interface AuditEntry {
  id: number;
  table_name: string;
  record_id: string | null;
  action: "INSERT" | "UPDATE" | "DELETE";
  old_data: Record<string, unknown> | null;
  new_data: Record<string, unknown> | null;
  changed_fields: string[] | null;
  actor_id: string | null;
  created_at: string;
}

/** Flattened variant used by POS / pickers. */
export interface CatalogItem {
  variant_id: string;
  product_id: string;
  product_name: string;
  image_url: string | null;
  category_id: string | null;
  sku: string;
  barcode: string | null;
  size: string | null;
  color: string | null;
  color_hex: string | null;
  price: number;
  stock_qty: number;
}

export interface ShiftNumbers {
  opening_cash: number;
  sales_count: number;
  returns_count: number;
  total_sales: number;
  // below: managers always; the cashier only after the shift is closed
  cash_sales?: number;
  card_sales?: number;
  transfer_sales?: number;
  exchange_credit?: number;
  cash_refunds?: number;
  card_refunds?: number;
  transfer_refunds?: number;
  exchange_returns?: number;
  cash_in?: number;
  cash_out?: number;
  expected_cash?: number;
}

export interface ShiftSummary {
  id: string;
  shift_no: string;
  status: "open" | "closed";
  cashier_id: string;
  cashier_name: string | null;
  opened_at: string;
  closed_at: string | null;
  closed_by_name: string | null;
  counted_cash: number | null;
  cash_difference: number | null;
  opening_notes: string | null;
  closing_notes: string | null;
  numbers: ShiftNumbers;
  movements: { type: "in" | "out"; amount: number; reason: string; created_at: string }[];
}

export interface ShiftListRow {
  id: string;
  shift_no: string;
  status: "open" | "closed";
  cashier_name: string | null;
  is_mine: boolean;
  opened_at: string;
  closed_at: string | null;
  opening_cash: number;
  total_sales: number;
  expected_cash: number | null;
  counted_cash: number | null;
  cash_difference: number | null;
}

export interface OpenShift {
  id: string;
  shift_no: string;
  opened_at: string;
  opening_cash: number;
}

export type ExpensePayment = "cash_drawer" | "cash" | "card" | "transfer";

export interface ExpenseCategory {
  id: string;
  name: string;
  sort_order: number;
}

export interface Expense {
  id: string;
  expense_no: string;
  category_id: string;
  expense_date: string;
  amount: number;
  vat_amount: number;
  payment_method: ExpensePayment;
  payee: string | null;
  reference: string | null;
  notes: string | null;
  receipt_path: string | null;
  shift_movement_id: string | null;
  created_at: string;
}

export interface ExpensesSummary {
  total: number;
  vat: number;
  net: number;
  count: number;
  from_drawer: number;
  by_category: { name: string; total: number; net: number; count: number }[];
}
