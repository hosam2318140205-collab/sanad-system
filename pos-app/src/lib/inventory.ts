// Smart Inventory 2.0: أنواع وتسميات ودوال جلب مشتركة بين شاشات المواقع والتحويلات والجرد ومركز القرار
import { supabase } from "@/lib/supabase/client";

export type LocationKind = "store" | "warehouse" | "transit";
export type TransferStatus = "requested" | "approved" | "in_transit" | "short_received" | "completed" | "rejected" | "cancelled";
export type DecisionAction = "transfer" | "order" | "markdown" | "promo" | "review";

export interface Location {
  id: string;
  code: string;
  name: string;
  kind: LocationKind;
  is_default: boolean;
  is_active: boolean;
  address: string | null;
  phone: string | null;
}

export interface Transfer {
  id: string;
  transfer_no: string;
  from_location: string;
  to_location: string;
  status: TransferStatus;
  notes: string | null;
  requested_by: string | null;
  requested_at: string;
  approved_by: string | null;
  approved_at: string | null;
  closed_by: string | null;
  closed_at: string | null;
  close_reason: string | null;
  completed_at: string | null;
}

export interface TransferItem {
  id: string;
  variant_id: string;
  qty_requested: number;
  qty_approved: number;
  qty_shipped: number;
  qty_received: number;
  qty_lost: number;
  discrepancy_by: string | null;
  variant: { sku: string; barcode: string | null; size: string | null; color: string | null; product: { name: string } };
}

export interface TransferEvent {
  id: number;
  event: string;
  variant_id: string | null;
  qty: number | null;
  note: string | null;
  created_by: string | null;
  created_at: string;
}

export interface Availability {
  location_id: string;
  location_name: string;
  location_kind: LocationKind;
  variant_id: string;
  product_id: string;
  product_name: string;
  category_id: string | null;
  sku: string;
  barcode: string | null;
  size: string | null;
  color: string | null;
  on_hand: number;
  reserved: number;
  outgoing: number;
  available: number;
  in_transit: number;
  incoming_approved: number;
  n7: number;
  n30: number;
  n60: number;
  n90: number;
  last_sale_at: string | null;
  unit_cost: number;
  unit_price: number;
  age_days: number | null;
}

export interface Decision {
  action: DecisionAction;
  priority: number;
  variant_id: string;
  sku: string;
  product_name: string;
  variant_label: string | null;
  from_location: string | null;
  from_name: string | null;
  to_location: string | null;
  to_name: string | null;
  qty: number;
  unit_cost: number;
  unit_price: number;
  cost_value: number;
  retail_value: number;
  reason: string;
  why: Record<string, unknown> | null;
}

export interface Gap {
  location_id: string;
  location_name: string;
  product_id: string;
  product_name: string;
  size: string | null;
  color: string | null;
  variant_id: string | null;
  gap_kind: "out_of_stock" | "not_created";
  variant_sold_90: number;
  model_sold_90: number;
  model_sizes_in_stock: number;
  available_elsewhere: number;
  priority: number;
  reason: string;
}

export interface Anomaly {
  kind: string;
  severity: "high" | "medium" | "low";
  location_id: string | null;
  location_name: string | null;
  variant_id: string | null;
  sku: string | null;
  product_name: string | null;
  variant_label: string | null;
  qty: number | null;
  value: number | null;
  reason: string;
  ref_id: string | null;
}

export interface DeadRow {
  location_id: string;
  location_name: string;
  variant_id: string;
  sku: string;
  product_name: string;
  variant_label: string | null;
  on_hand: number;
  idle_days: number;
  bucket: 30 | 60 | 90 | 180;
  last_sale_at: string | null;
  best_location_id: string | null;
  best_location_name: string | null;
  best_location_sold_30: number;
  action: "transfer" | "promo" | "markdown" | "none";
  suggested_qty: number;
  cost_value: number;
  retail_value: number;
  reason: string;
}

export interface VariantLocation {
  location_id: string;
  location_name: string;
  kind: LocationKind;
  on_hand: number;
  available: number;
}

export interface PosLocationContext {
  multi: boolean;
  location_id?: string;
  location_name?: string;
  stock?: Record<string, number>;
}

export const LOCATION_KIND_LABELS: Record<LocationKind, string> = {
  store: "فرع",
  warehouse: "مستودع",
  transit: "بضاعة بالطريق",
};

export const TRANSFER_STATUS: Record<TransferStatus, { label: string; tone: "blue" | "amber" | "violet" | "red" | "green" | "slate" }> = {
  requested: { label: "بانتظار الاعتماد", tone: "amber" },
  approved: { label: "معتمد — بانتظار الشحن", tone: "blue" },
  in_transit: { label: "بالطريق", tone: "violet" },
  short_received: { label: "استلام ناقص — فرق معلق", tone: "red" },
  completed: { label: "مكتمل", tone: "green" },
  rejected: { label: "مرفوض", tone: "slate" },
  cancelled: { label: "ملغي", tone: "slate" },
};

export const TRANSFER_EVENTS: Record<string, string> = {
  request: "طلب",
  approve: "اعتماد",
  reject: "رفض",
  cancel: "إلغاء",
  ship: "شحن",
  close_remaining: "إنهاء الشحن (إلغاء غير المشحون)",
  receive: "استلام",
  finalize: "إنهاء الاستلام",
  loss: "اعتماد فقد",
};

export const DECISION_ACTIONS: Record<DecisionAction, { label: string; tone: "blue" | "amber" | "violet" | "red" | "green" | "slate" }> = {
  transfer: { label: "انقل", tone: "blue" },
  order: { label: "اطلب شراء", tone: "green" },
  markdown: { label: "خفّض السعر", tone: "red" },
  promo: { label: "عرض ترويجي", tone: "violet" },
  review: { label: "راجع", tone: "amber" },
};

export const ANOMALY_KINDS: Record<string, string> = {
  negative_stock: "رصيد سالب",
  invariant: "تعارض الإجمالي مع المواقع",
  transfer_discrepancy: "فرق تحويل معلق",
  stale_transit: "تحويل متأخر بالطريق",
  count_variance: "فرق جرد",
  large_adjustment: "تسوية كبيرة",
  sales_spike: "قفزة مبيعات غير معتادة",
  missing_cost: "بدون تكلفة",
  missing_barcode: "بدون باركود",
};

export const DEAD_ACTIONS: Record<DeadRow["action"], string> = {
  transfer: "انقل لفرع يبيعه",
  promo: "عرض ترويجي",
  markdown: "تخفيض سعر",
  none: "لا إجراء",
};

export function newRef(): string {
  return crypto.randomUUID();
}

/** المواقع الفعلية (فروع ومستودعات) — الموقع الافتراضي أولاً */
export async function fetchLocations(includeInactive = false): Promise<Location[]> {
  let q = supabase().from("locations").select("*").neq("kind", "transit");
  if (!includeInactive) q = q.eq("is_active", true);
  const { data, error } = await q.order("is_default", { ascending: false }).order("name");
  if (error) throw error;
  return (data ?? []) as Location[];
}

/** دوال RPC ترجع جداول: نجلب على دفعات لأن PostgREST يحد عدد الصفوف */
export async function rpcAll<T>(fn: string, args: Record<string, unknown> = {}): Promise<T[]> {
  const all: T[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await supabase()
      .rpc(fn, args)
      .range(from, from + 999);
    if (error) throw error;
    const rows = (data ?? []) as T[];
    all.push(...rows);
    if (rows.length < 1000) return all;
  }
}

/** تحويل الأرقام القادمة كنصوص من numeric */
export function n(v: unknown): number {
  return Number(v ?? 0) || 0;
}

/** موقع الموظف: تعيينه في staff_locations وإلا الموقع الافتراضي */
export async function fetchMyLocationId(profileId: string, locations: Location[]): Promise<string> {
  const { data } = await supabase().from("staff_locations").select("location_id").eq("profile_id", profileId).maybeSingle();
  return (data?.location_id as string | undefined) ?? locations.find((l) => l.is_default)?.id ?? locations[0]?.id ?? "";
}
