// مساعد الشراء الذكي — الأرقام تُحسب في قاعدة البيانات (purchase_advisor)، وهنا التصنيف والشرح فقط.

export interface AdvisorParams {
  lead: number; // مدة التوريد بالأيام
  cover: number; // أيام التغطية المطلوبة بعد وصول الطلب
  safety: number; // أيام أمان إضافية
}

export const DEFAULT_PARAMS: AdvisorParams = { lead: 7, cover: 30, safety: 7 };

export interface AdvisorRow {
  variant_id: string;
  product_id: string;
  product_name: string;
  category_name: string | null;
  size: string | null;
  color: string | null;
  sku: string;
  barcode: string | null;
  is_active: boolean;
  stock: number;
  on_order: number;
  unit_cost: number;
  unit_price: number;
  sold_7: number;
  sold_30: number;
  sold_90: number;
  age_days: number;
  avg_daily: number;
  cover_days: number | null;
  reorder_point: number;
  target_qty: number;
  suggested_qty: number;
  last_sale_at: string | null;
  idle_days: number;
  supplier_id: string | null;
  supplier_name: string | null;
}

export type AdvisorStatus = "out" | "reorder" | "ok" | "excess" | "no_sales";

export const STATUS_META: Record<AdvisorStatus, { label: string; tone: "red" | "amber" | "green" | "blue" | "slate" }> = {
  out: { label: "نفد", tone: "red" },
  reorder: { label: "اطلب الآن", tone: "amber" },
  ok: { label: "كافٍ", tone: "green" },
  excess: { label: "فائض", tone: "blue" },
  no_sales: { label: "بلا مبيعات 90 يوماً", tone: "slate" },
};

/** PostgREST يعيد numeric كنص أحياناً — نوحّد الأنواع. */
export function normalizeRow(r: AdvisorRow): AdvisorRow {
  return {
    ...r,
    unit_cost: Number(r.unit_cost),
    unit_price: Number(r.unit_price),
    avg_daily: Number(r.avg_daily),
    cover_days: r.cover_days === null ? null : Number(r.cover_days),
  };
}

export function statusOf(r: AdvisorRow, p: AdvisorParams): AdvisorStatus {
  if (r.avg_daily <= 0) return "no_sales";
  if (r.stock <= 0) return "out";
  if (r.suggested_qty > 0) return "reorder";
  // المخزون يغطي أكثر من ضعف دورة الشراء الكاملة
  if (r.cover_days !== null && r.cover_days > 2 * (p.lead + p.safety + p.cover)) return "excess";
  return "ok";
}

const f3 = (n: number) => Number(n.toFixed(3)).toString();

/** سطر شرح: نص عربي + معادلة تُعرض من اليسار لليمين حتى لا تختلط الأرقام. */
export interface ExplainLine {
  text: string;
  math?: string;
}

/** شرح الحساب بالأرقام الفعلية للصنف — ليعرف المستخدم لماذا اقترح النظام هذه الكمية. */
export function explain(r: AdvisorRow, p: AdvisorParams): ExplainLine[] {
  const d7 = Math.min(7, r.age_days);
  const d30 = Math.min(30, r.age_days);
  const d90 = Math.min(90, r.age_days);
  const lines: ExplainLine[] = [
    {
      text:
        `صافي المباع بعد المرتجعات: ${r.sold_7} خلال ${d7} يوم، ${r.sold_30} خلال ${d30} يوماً، ${r.sold_90} خلال ${d90} يوماً` +
        (r.age_days < 90 ? ` (عمر الصنف ${r.age_days} يوماً، فالقسمة على عمره الفعلي)` : ""),
    },
    {
      text: "متوسط البيع اليومي (قطعة/يوم):",
      math: `0.2×${r.sold_7}/${d7} + 0.5×${r.sold_30}/${d30} + 0.3×${r.sold_90}/${d90} = ${f3(r.avg_daily)}`,
    },
  ];
  if (r.avg_daily <= 0) {
    lines.push({ text: "لا مبيعات خلال 90 يوماً، فلا توصية بالشراء." });
    return lines;
  }
  const available = Math.max(r.stock, 0) + r.on_order;
  lines.push(
    {
      text:
        `المخزون الحالي ${r.stock} يكفي نحو ${r.cover_days ?? 0} يوماً بالمعدل الحالي` +
        (r.on_order ? `، وفي أوامر شراء مفتوحة (مسودة/مطلوب) ${r.on_order} قطعة` : ""),
    },
    {
      text: `نقطة إعادة الطلب = المتوسط × (${p.lead} توريد + ${p.safety} أمان):`,
      math: `${f3(r.avg_daily)} × ${p.lead + p.safety} = ${f3(r.avg_daily * (p.lead + p.safety))} → ${r.reorder_point}`,
    },
    {
      text: `المستوى المستهدف = المتوسط × (التوريد + الأمان + ${p.cover} تغطية):`,
      math: `${f3(r.avg_daily)} × ${p.lead + p.safety + p.cover} = ${f3(r.avg_daily * (p.lead + p.safety + p.cover))} → ${r.target_qty}`,
    },
    r.suggested_qty > 0
      ? { text: `المتاح ${available} وصل إلى نقطة الطلب ${r.reorder_point}، فالمقترح = المستهدف − المتاح:`, math: `${r.target_qty} − ${available} = ${r.suggested_qty}` }
      : { text: `المتاح ${available} أعلى من نقطة الطلب ${r.reorder_point}، فلا حاجة للطلب الآن.` },
  );
  return lines;
}

export const DEAD_BUCKETS = [30, 60, 90] as const;
export type DeadBucket = (typeof DEAD_BUCKETS)[number];

/** راكد = له مخزون ولم يُبع منذ N يوماً على الأقل (أو منذ دخوله المخزون إن لم يُبع أبداً). */
export function isDead(r: AdvisorRow, days: number): boolean {
  return r.stock > 0 && r.idle_days >= days;
}

export function deadSummary(rows: AdvisorRow[], days: number) {
  const items = rows.filter((r) => isDead(r, days));
  return {
    count: items.length,
    units: items.reduce((s, r) => s + r.stock, 0),
    cost: items.reduce((s, r) => s + r.stock * r.unit_cost, 0),
    retail: items.reduce((s, r) => s + r.stock * r.unit_price, 0),
    items,
  };
}

export function loadParams(): AdvisorParams {
  try {
    const raw = localStorage.getItem("advisor-params");
    if (!raw) return DEFAULT_PARAMS;
    const p = JSON.parse(raw) as Partial<AdvisorParams>;
    return {
      lead: clampInt(p.lead, 0, 365, DEFAULT_PARAMS.lead),
      cover: clampInt(p.cover, 1, 365, DEFAULT_PARAMS.cover),
      safety: clampInt(p.safety, 0, 365, DEFAULT_PARAMS.safety),
    };
  } catch {
    return DEFAULT_PARAMS;
  }
}

export function saveParams(p: AdvisorParams) {
  try {
    localStorage.setItem("advisor-params", JSON.stringify(p));
  } catch {
    // التخزين المحلي غير متاح — تبقى القيم لهذه الجلسة فقط
  }
}

export function clampInt(v: unknown, min: number, max: number, fallback: number): number {
  const n = Math.round(Number(v));
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}
