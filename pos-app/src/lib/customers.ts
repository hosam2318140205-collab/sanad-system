// أدوات العملاء: واتساب، رابط الفاتورة العام، تسميات دفاتر الذمم والنقاط، والحجوزات
import { dateTime, money } from "./format";
import { supabase } from "./supabase/client";
import type { ArEntryType, CollectionMethod, LoyaltyEntryType, PromoKind, Reservation, StoreSettings } from "./types";

export const AR_ENTRY_LABELS: Record<ArEntryType, string> = {
  sale: "فاتورة آجلة",
  return: "مرتجع إلى الحساب",
  receipt: "تحصيل",
  refund: "رد رصيد للعميل",
  void: "إلغاء سند",
  adjust: "تسوية",
};

export const LOYALTY_ENTRY_LABELS: Record<LoyaltyEntryType, string> = {
  earn: "نقاط مكتسبة",
  redeem: "نقاط مستبدلة",
  return_reverse: "عكس نقاط (مرتجع)",
  return_restore: "استرجاع نقاط (مرتجع)",
  adjust: "تعديل يدوي",
};

export const COLLECTION_METHOD_LABELS: Record<CollectionMethod, string> = {
  cash_drawer: "نقداً في درج الوردية",
  cash: "نقداً (خارج الدرج)",
  card: "شبكة",
  transfer: "تحويل بنكي",
};

export const PROMO_KIND_LABELS: Record<PromoKind, string> = {
  percent: "نسبة % من السعر",
  amount: "مبلغ لكل قطعة",
  bxgy: "اشترِ X واحصل على Y مجاناً",
};

/**
 * يحوّل رقم الجوال إلى الصيغة الدولية المطلوبة لواتساب (بدون + أو أصفار بادئة).
 * 05xxxxxxxx أو 5xxxxxxxx ← 9665xxxxxxxx. يعيد null إن لم يكن رقماً صالحاً.
 */
export function waPhone(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let d = raw.replace(/\D/g, "");
  if (d.startsWith("00")) d = d.slice(2);
  if (/^05\d{8}$/.test(d)) d = "966" + d.slice(1);
  else if (/^5\d{8}$/.test(d)) d = "966" + d;
  return /^\d{8,15}$/.test(d) ? d : null;
}

export function waLink(phone: string, text: string): string {
  return `https://wa.me/${phone}?text=${encodeURIComponent(text)}`;
}

export function publicReceiptUrl(token: string): string {
  return `${window.location.origin}/r/${token}`;
}

export function receiptMessage(input: {
  settings: StoreSettings;
  customerName?: string | null;
  invoiceNo: string;
  createdAt: string;
  total: number;
  vat: number;
  pointsEarned?: number;
  pointsBalance?: number | null;
  onAccount?: number;
  token?: string;
}): string {
  const lines = [
    input.customerName ? `مرحباً ${input.customerName}،` : "مرحباً،",
    `شكراً لتسوقك من ${input.settings.store_name}.`,
    "",
    `فاتورة رقم: ${input.invoiceNo}`,
    `التاريخ: ${dateTime(input.createdAt)}`,
    `الإجمالي: ${money(input.total)} (شامل ضريبة القيمة المضافة ${money(input.vat)})`,
  ];
  if (input.onAccount && input.onAccount > 0) lines.push(`المبلغ الآجل على حسابك: ${money(input.onAccount)}`);
  if (input.pointsEarned && input.pointsEarned > 0) {
    lines.push(`نقاط مكتسبة: ${input.pointsEarned}` + (input.pointsBalance != null ? ` — رصيدك: ${input.pointsBalance} نقطة` : ""));
  }
  if (input.token) lines.push("", `عرض الفاتورة: ${publicReceiptUrl(input.token)}`);
  return lines.join("\n");
}

/** يفتح واتساب ويسجل العملية (السجل لا يمنع الإرسال إن فشل). */
export async function openWhatsApp(opts: {
  phone: string;
  text: string;
  kind: "receipt" | "statement" | "reservation" | "reminder";
  saleId?: string | null;
  customerId?: string | null;
  reservationId?: string | null;
}) {
  window.open(waLink(opts.phone, opts.text), "_blank", "noopener");
  const db = supabase();
  const { data } = await db.auth.getUser();
  await db.from("message_log").insert({
    kind: opts.kind,
    phone: opts.phone,
    sale_id: opts.saleId ?? null,
    customer_id: opts.customerId ?? null,
    reservation_id: opts.reservationId ?? null,
    created_by: data.user?.id,
  });
}

export function isReservationExpired(r: Pick<Reservation, "status" | "expires_at">): boolean {
  return r.status === "active" && new Date(r.expires_at).getTime() <= Date.now();
}

export function reservationState(r: Pick<Reservation, "status" | "expires_at">): {
  label: string;
  tone: "green" | "amber" | "slate" | "red" | "blue";
} {
  if (r.status === "fulfilled") return { label: "تم الاستلام", tone: "green" };
  if (r.status === "cancelled") return { label: "ملغي", tone: "slate" };
  if (new Date(r.expires_at).getTime() <= Date.now()) return { label: "منتهي", tone: "red" };
  return { label: "نشط", tone: "blue" };
}

/** مفتاح منع التكرار لكل عملية مالية (يُعاد استخدامه عند إعادة المحاولة لنفس العملية). */
export function newClientRef(): string {
  return crypto.randomUUID();
}
