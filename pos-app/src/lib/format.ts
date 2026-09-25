import type { ExpensePayment, MovementType, PaymentMethod, PurchaseStatus, RefundMethod, SaleStatus, UserRole } from "./types";

const moneyFmt = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const intFmt = new Intl.NumberFormat("en-US");

export function money(value: number | string | null | undefined): string {
  return `${moneyFmt.format(Number(value ?? 0))} ر.س`;
}

export function num(value: number | string | null | undefined): string {
  return intFmt.format(Number(value ?? 0));
}

export function round2(value: number): number {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

const TZ = "Asia/Riyadh";

export function dateTime(value: string | Date | null | undefined): string {
  if (!value) return "-";
  return new Date(value).toLocaleString("en-GB", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: true,
  });
}

export function dateOnly(value: string | Date | null | undefined): string {
  if (!value) return "-";
  return new Date(value).toLocaleDateString("en-GB", { timeZone: TZ });
}

/** YYYY-MM-DD in Riyadh time. */
export function isoDay(d: Date = new Date()): string {
  return d.toLocaleDateString("en-CA", { timeZone: TZ });
}

export function variantLabel(size: string | null | undefined, color: string | null | undefined): string {
  return [size, color].filter(Boolean).join(" / ");
}

export const ROLE_LABELS: Record<UserRole, string> = {
  owner: "المالك",
  manager: "مدير",
  cashier: "كاشير",
};

export const PAYMENT_LABELS: Record<PaymentMethod, string> = {
  cash: "نقدي",
  card: "شبكة (مدى/فيزا)",
  transfer: "تحويل بنكي",
  exchange_credit: "رصيد استبدال",
  on_account: "آجل (على الحساب)",
};

export const EXPENSE_PAYMENT_LABELS: Record<ExpensePayment, string> = {
  cash_drawer: "من درج الوردية",
  cash: "نقدي (خارج الدرج)",
  card: "شبكة / بطاقة",
  transfer: "تحويل بنكي",
};

export const REFUND_LABELS: Record<RefundMethod, string> = {
  cash: "نقدي",
  card: "شبكة",
  transfer: "تحويل",
  exchange: "استبدال (رصيد)",
  account: "إلى حساب العميل",
};

export const SALE_STATUS_LABELS: Record<SaleStatus, string> = {
  completed: "مكتملة",
  partially_returned: "مرتجع جزئي",
  returned: "مرتجعة",
};

export const PURCHASE_STATUS_LABELS: Record<PurchaseStatus, string> = {
  draft: "مسودة",
  ordered: "مطلوب",
  received: "مستلم",
  cancelled: "ملغي",
};

export const MOVEMENT_LABELS: Record<MovementType, string> = {
  opening: "رصيد افتتاحي",
  sale: "بيع",
  return: "مرتجع",
  purchase: "مشتريات",
  adjustment: "تسوية",
  count: "جرد",
};

/** Extract a readable message from Supabase / unknown errors. */
export function errorMessage(err: unknown): string {
  if (!err) return "حدث خطأ غير متوقع";
  if (typeof err === "string") return err;
  if (typeof err === "object" && err !== null && "message" in err) {
    const msg = String((err as { message: unknown }).message);
    if (msg.includes("duplicate key")) {
      if (msg.includes("barcode")) return "الباركود مستخدم لصنف آخر";
      if (msg.includes("sku")) return "رمز الصنف (SKU) مستخدم مسبقاً";
      if (msg.includes("phone")) return "رقم الجوال مسجل لعميل آخر";
      return "القيمة مسجلة مسبقاً";
    }
    if (msg.includes("row-level security") || msg.includes("permission denied")) {
      return "ليست لديك صلاحية لتنفيذ هذه العملية";
    }
    if (msg.includes("violates foreign key")) return "لا يمكن الحذف لارتباطه بعمليات أخرى";
    return msg;
  }
  return "حدث خطأ غير متوقع";
}
