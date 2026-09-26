"use client";

import {
  ChevronDown,
  Download,
  FilePlus2,
  HelpCircle,
  Lightbulb,
  PackageX,
  RefreshCw,
  ShoppingBag,
  Snowflake,
} from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Fragment, useEffect, useMemo, useState } from "react";
import {
  Badge,
  Button,
  Card,
  EmptyState,
  Field,
  Input,
  Loading,
  Modal,
  PageHeader,
  Select,
  Stat,
  Table,
  cn,
  useToast,
} from "@/components/ui";
import {
  DEAD_BUCKETS,
  STATUS_META,
  clampInt,
  deadSummary,
  explain,
  loadParams,
  normalizeRow,
  saveParams,
  statusOf,
  type AdvisorParams,
  type AdvisorRow,
  type AdvisorStatus,
  type DeadBucket,
} from "@/lib/advisor";
import { downloadCsv } from "@/lib/csv";
import {
  dateOnly,
  errorMessage,
  isoDay,
  money,
  num,
  round2,
  variantLabel,
} from "@/lib/format";
import type { SupplierSuggestion } from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";
import type { Supplier } from "@/lib/types";

type Filter = "need" | "all" | AdvisorStatus;
const FILTERS: Array<[Filter, string]> = [
  ["need", "تحتاج طلب"],
  ["all", "كل الأصناف"],
  ["out", "نفد"],
  ["ok", "كافٍ"],
  ["excess", "فائض"],
  ["no_sales", "بلا مبيعات"],
];
const PAGE = 1000;
const SHOW_STEP = 150;
const NO_SUPPLIER = "none";

async function fetchAdvisor(p: AdvisorParams): Promise<AdvisorRow[]> {
  const db = supabase();
  const all: AdvisorRow[] = [];
  // PostgREST يحد عدد الصفوف في الطلب الواحد — نجلب على دفعات
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await db
      .rpc("purchase_advisor", {
        p_lead_days: p.lead,
        p_cover_days: p.cover,
        p_safety_days: p.safety,
      })
      .range(from, from + PAGE - 1);
    if (error) throw error;
    const rows = (data ?? []) as AdvisorRow[];
    all.push(...rows.map(normalizeRow));
    if (rows.length < PAGE) return all;
  }
}

export function AdvisorScreen() {
  const toast = useToast();
  const router = useRouter();
  const [params, setParams] = useState<AdvisorParams | null>(null);
  const [form, setForm] = useState({ lead: "", cover: "", safety: "" });
  const [rows, setRows] = useState<AdvisorRow[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [tab, setTab] = useState<"buy" | "dead">("buy");
  const [filter, setFilter] = useState<Filter>("need");
  const [q, setQ] = useState("");
  const [supplierFilter, setSupplierFilter] = useState("");
  const [selected, setSelected] = useState<Record<string, string>>({});
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [shown, setShown] = useState(SHOW_STEP);
  const [deadDays, setDeadDays] = useState<DeadBucket>(90);
  const [draftOpen, setDraftOpen] = useState(false);
  const [groupSupplier, setGroupSupplier] = useState<Record<string, string>>(
    {},
  );
  const [creating, setCreating] = useState(false);
  // المورد الأنسب لكل صنف (0020) مع «لماذا؟»
  const [advice, setAdvice] = useState<Record<string, SupplierSuggestion>>({});
  const [adviceOpen, setAdviceOpen] = useState<string | null>(null);

  const run = async (p: AdvisorParams) => {
    try {
      const data = await fetchAdvisor(p);
      setParams(p);
      setForm({
        lead: String(p.lead),
        cover: String(p.cover),
        safety: String(p.safety),
      });
      setRows(data);
      // التحديدات لأصناف لم تعد موجودة تُحذف
      setSelected((s) =>
        Object.fromEntries(
          Object.entries(s).filter(([id]) =>
            data.some((r) => r.variant_id === id),
          ),
        ),
      );
    } catch (e) {
      toast(errorMessage(e), "error");
      setRows((r) => r ?? []);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    (async () => {
      const { data } = await supabase()
        .from("suppliers")
        .select("*")
        .eq("is_active", true)
        .order("name");
      setSuppliers((data ?? []) as Supplier[]);
    })();
    (async () => {
      await run(loadParams());
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const recalc = () => {
    const p: AdvisorParams = {
      lead: clampInt(form.lead, 0, 365, 7),
      cover: clampInt(form.cover, 1, 365, 30),
      safety: clampInt(form.safety, 0, 365, 7),
    };
    saveParams(p);
    setLoading(true);
    void run(p);
  };

  const statuses = useMemo(() => {
    const m = new Map<string, AdvisorStatus>();
    if (rows && params)
      for (const r of rows) m.set(r.variant_id, statusOf(r, params));
    return m;
  }, [rows, params]);

  const supplierOptions = useMemo(() => {
    const m = new Map<string, string>();
    for (const r of rows ?? [])
      if (r.supplier_id) m.set(r.supplier_id, r.supplier_name ?? "");
    return [...m].sort((a, b) => a[1].localeCompare(b[1], "ar"));
  }, [rows]);

  const matchesSearch = (r: AdvisorRow) => {
    const s = q.trim().toLowerCase();
    if (
      supplierFilter === NO_SUPPLIER
        ? r.supplier_id
        : supplierFilter && r.supplier_id !== supplierFilter
    )
      return false;
    if (!s) return true;
    return [
      r.product_name,
      r.sku,
      r.barcode,
      r.size,
      r.color,
      r.category_name,
    ].some((v) => v?.toLowerCase().includes(s));
  };

  const buyRows = useMemo(() => {
    if (!rows) return [];
    const list = rows.filter((r) => {
      const st = statuses.get(r.variant_id)!;
      if (
        filter === "need"
          ? r.suggested_qty <= 0
          : filter !== "all" && st !== filter
      )
        return false;
      return matchesSearch(r);
    });
    // الأهم أولاً: نفد ← اطلب الآن (الأقل تغطية) ← الباقي
    const rank: Record<AdvisorStatus, number> = {
      out: 0,
      reorder: 1,
      ok: 2,
      excess: 3,
      no_sales: 4,
    };
    return list.sort(
      (a, b) =>
        rank[statuses.get(a.variant_id)!] - rank[statuses.get(b.variant_id)!] ||
        (a.cover_days ?? Infinity) - (b.cover_days ?? Infinity) ||
        b.avg_daily - a.avg_daily,
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, statuses, filter, q, supplierFilter]);

  const dead = useMemo(() => {
    const all = rows ?? [];
    const byBucket = Object.fromEntries(
      DEAD_BUCKETS.map((d) => [d, deadSummary(all, d)]),
    ) as Record<DeadBucket, ReturnType<typeof deadSummary>>;
    const items = byBucket[deadDays].items
      .filter(matchesSearch)
      .sort((a, b) => b.stock * b.unit_cost - a.stock * a.unit_cost);
    return { byBucket, items };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, deadDays, q, supplierFilter]);

  if (loading && !rows)
    return <Loading label="جاري تحليل المبيعات والمخزون..." />;
  const all = rows ?? [];
  const p = params!;

  const need = all.filter((r) => r.suggested_qty > 0);
  const outCount = all.filter(
    (r) => statuses.get(r.variant_id) === "out",
  ).length;
  const suggestedCost = need.reduce(
    (s, r) => s + r.suggested_qty * r.unit_cost,
    0,
  );

  const selectedRows = all.filter((r) => selected[r.variant_id] !== undefined);
  const selUnits = selectedRows.reduce(
    (s, r) => s + (Number(selected[r.variant_id]) || 0),
    0,
  );
  const selCost = selectedRows.reduce(
    (s, r) => s + (Number(selected[r.variant_id]) || 0) * r.unit_cost,
    0,
  );

  const toggle = (r: AdvisorRow, on: boolean) =>
    setSelected((s) => {
      const next = { ...s };
      if (on)
        next[r.variant_id] = String(r.suggested_qty > 0 ? r.suggested_qty : 1);
      else delete next[r.variant_id];
      return next;
    });
  const visibleBuy = buyRows.slice(0, shown);
  const allVisibleSelected =
    visibleBuy.length > 0 &&
    visibleBuy.every((r) => selected[r.variant_id] !== undefined);
  const toggleAllVisible = (on: boolean) =>
    setSelected((s) => {
      const next = { ...s };
      for (const r of visibleBuy) {
        if (on)
          next[r.variant_id] ??= String(
            r.suggested_qty > 0 ? r.suggested_qty : 1,
          );
        else delete next[r.variant_id];
      }
      return next;
    });
  const toggleExpanded = (id: string) =>
    setExpanded((e) => {
      const n = new Set(e);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  // تجميع المحدد حسب آخر مورد اشتُري منه الصنف
  const groups = (() => {
    const m = new Map<
      string,
      { key: string; name: string; rows: AdvisorRow[] }
    >();
    for (const r of selectedRows) {
      const key = r.supplier_id ?? NO_SUPPLIER;
      if (!m.has(key))
        m.set(key, {
          key,
          name: r.supplier_name ?? "بدون مورد سابق",
          rows: [],
        });
      m.get(key)!.rows.push(r);
    }
    return [...m.values()];
  })();

  const openDraft = () => {
    const invalid = selectedRows.find(
      (r) =>
        !(Number(selected[r.variant_id]) > 0) ||
        !Number.isInteger(Number(selected[r.variant_id])),
    );
    if (invalid) return toast(`كمية غير صحيحة للصنف ${invalid.sku}`, "error");
    setGroupSupplier(
      Object.fromEntries(
        groups.map((g) => [g.key, g.key === NO_SUPPLIER ? "" : g.key]),
      ),
    );
    setDraftOpen(true);
    supabase()
      .rpc("suggest_suppliers", { p_variants: selectedRows.map((r) => r.variant_id) })
      .then(({ data }) => {
        const map = Object.fromEntries(
          ((data ?? []) as SupplierSuggestion[]).map((x) => [x.variant_id, x]),
        );
        setAdvice(map);
        // أصناف بلا مورد سابق: المقترح إن اتفقت أصناف المجموعة عليه
        const none = groups.find((g) => g.key === NO_SUPPLIER);
        const ids = new Set(none?.rows.map((r) => map[r.variant_id]?.supplier_id));
        if (none && ids.size === 1 && [...ids][0])
          setGroupSupplier((gs) => ({ ...gs, [NO_SUPPLIER]: [...ids][0] as string }));
      });
  };

  const createDrafts = async () => {
    // مجموعات بنفس المورد المختار تُدمج في مسودة واحدة
    const bySupplier = new Map<string, AdvisorRow[]>();
    for (const g of groups) {
      const sid = groupSupplier[g.key];
      if (!sid) return toast(`اختر المورد لمجموعة «${g.name}»`, "error");
      bySupplier.set(sid, [...(bySupplier.get(sid) ?? []), ...g.rows]);
    }
    setCreating(true);
    const created: string[] = [];
    const done = new Set<string>();
    try {
      for (const [sid, list] of bySupplier) {
        const { data, error } = await supabase().rpc("create_purchase_draft", {
          p_supplier_id: sid,
          p_items: list.map((r) => ({
            variant_id: r.variant_id,
            qty: Number(selected[r.variant_id]),
          })),
        });
        if (error) throw error;
        created.push(data as string);
        for (const r of list) done.add(r.variant_id);
      }
    } catch (e) {
      toast(errorMessage(e), "error");
    } finally {
      setCreating(false);
      setSelected((s) =>
        Object.fromEntries(Object.entries(s).filter(([id]) => !done.has(id))),
      );
    }
    if (!created.length) return;
    setDraftOpen(false);
    toast(
      created.length === 1
        ? "تم إنشاء مسودة أمر الشراء"
        : `تم إنشاء ${created.length} مسودات أوامر شراء`,
    );
    if (created.length === 1 && done.size === selectedRows.length)
      router.push(`/purchases/${created[0]}`);
    else {
      setLoading(true);
      void run(p);
    }
  };

  const exportCsv = () => {
    if (tab === "buy") {
      downloadCsv(
        `purchase-advisor-${isoDay()}.csv`,
        [
          "المنتج",
          "المقاس",
          "اللون",
          "SKU",
          "الحالة",
          "المخزون",
          "في أوامر مفتوحة",
          "مباع 7",
          "مباع 30",
          "مباع 90",
          "متوسط يومي",
          "أيام التغطية",
          "نقطة الطلب",
          "المستهدف",
          "المقترح",
          "التكلفة",
          "قيمة المقترح",
          "آخر مورد",
        ],
        buyRows.map((r) => [
          r.product_name,
          r.size,
          r.color,
          r.sku,
          STATUS_META[statuses.get(r.variant_id)!].label,
          r.stock,
          r.on_order,
          r.sold_7,
          r.sold_30,
          r.sold_90,
          r.avg_daily,
          r.cover_days,
          r.reorder_point,
          r.target_qty,
          r.suggested_qty,
          r.unit_cost,
          round2(r.suggested_qty * r.unit_cost),
          r.supplier_name,
        ]),
      );
    } else {
      downloadCsv(
        `dead-stock-${deadDays}d-${isoDay()}.csv`,
        [
          "المنتج",
          "المقاس",
          "اللون",
          "SKU",
          "المخزون",
          "أيام بلا بيع",
          "آخر بيع",
          "قيمة التكلفة",
          "قيمة البيع",
        ],
        dead.items.map((r) => [
          r.product_name,
          r.size,
          r.color,
          r.sku,
          r.stock,
          r.idle_days,
          r.last_sale_at ? dateOnly(r.last_sale_at) : "لم يُبع",
          round2(r.stock * r.unit_cost),
          round2(r.stock * r.unit_price),
        ]),
      );
    }
  };

  const status = (r: AdvisorRow) => {
    const m = STATUS_META[statuses.get(r.variant_id)!];
    return <Badge tone={m.tone}>{m.label}</Badge>;
  };
  const qtyInput = (r: AdvisorRow, className?: string) => (
    <div className={cn("shrink-0", className)}>
      <Input
        type="number"
        inputMode="numeric"
        min={1}
        step={1}
        aria-label={`كمية الشراء ${r.sku}`}
        className="h-9"
        value={selected[r.variant_id] ?? ""}
        placeholder={String(r.suggested_qty)}
        onChange={(e) =>
          setSelected((s) => ({ ...s, [r.variant_id]: e.target.value }))
        }
      />
    </div>
  );
  const why = (r: AdvisorRow) => (
    <ul className="list-inside list-disc space-y-0.5 text-xs leading-relaxed text-slate-600">
      {explain(r, p).map((l) => (
        <li key={l.text}>
          {l.text}
          {l.math && (
            <>
              {" "}
              <bdi
                dir="ltr"
                className="whitespace-nowrap font-medium text-slate-800 tabular-nums"
              >
                {l.math}
              </bdi>
            </>
          )}
        </li>
      ))}
    </ul>
  );

  return (
    <div>
      <PageHeader
        title="مساعد الشراء الذكي"
        subtitle="توصيات مبنية على مبيعاتك الفعلية لكل مقاس ولون — كل رقم قابل للتفسير"
        actions={
          <Button variant="outline" onClick={exportCsv}>
            <Download className="size-4" /> تصدير CSV
          </Button>
        }
      />

      <Card className="mb-4 p-4">
        <div className="grid grid-cols-3 gap-2 sm:gap-3 md:flex md:flex-wrap md:items-end">
          <Field label="مدة التوريد (يوم)" className="md:w-40">
            <Input
              type="number"
              inputMode="numeric"
              min={0}
              value={form.lead}
              onChange={(e) => setForm({ ...form, lead: e.target.value })}
            />
          </Field>
          <Field label="تغطية مطلوبة (يوم)" className="md:w-40">
            <Input
              type="number"
              inputMode="numeric"
              min={1}
              value={form.cover}
              onChange={(e) => setForm({ ...form, cover: e.target.value })}
            />
          </Field>
          <Field label="أيام أمان" className="md:w-40">
            <Input
              type="number"
              inputMode="numeric"
              min={0}
              value={form.safety}
              onChange={(e) => setForm({ ...form, safety: e.target.value })}
            />
          </Field>
          <Button
            className="col-span-3 md:col-span-1"
            onClick={recalc}
            disabled={loading}
          >
            <RefreshCw className={cn("size-4", loading && "animate-spin")} />{" "}
            إعادة الحساب
          </Button>
        </div>
        <details className="mt-3 text-sm text-slate-600">
          <summary className="flex cursor-pointer items-center gap-1 font-medium text-brand-800">
            <HelpCircle className="size-4" /> كيف تُحسب التوصيات؟
          </summary>
          <ul className="mt-2 list-inside list-disc space-y-1 leading-relaxed">
            <li>
              صافي المباع = الكميات المباعة − المرتجعة، لكل صنف (منتج + مقاس +
              لون).
            </li>
            <li>
              متوسط البيع اليومي = 20% من معدل آخر 7 أيام + 50% من آخر 30 + 30%
              من آخر 90. الصنف الأحدث من النافذة يُقسم على عمره الفعلي.
            </li>
            <li>أيام التغطية = المخزون الحالي ÷ متوسط البيع اليومي.</li>
            <li>نقطة إعادة الطلب = المتوسط × (مدة التوريد + أيام الأمان).</li>
            <li>
              المقترح = المتوسط × (التوريد + الأمان + التغطية المطلوبة) −
              المخزون − الكميات في أوامر شراء مفتوحة، ويظهر فقط عندما ينزل
              المتاح إلى نقطة الطلب.
            </li>
            <li>
              الراكد = صنف له مخزون ولم يُبع منذ 30/60/90 يوماً (أو منذ دخوله
              المخزون إن لم يُبع أبداً). قيمته بسعر التكلفة.
            </li>
          </ul>
        </details>
      </Card>

      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat
          label="أصناف تحتاج طلب"
          value={num(need.length)}
          tone="amber"
          icon={<ShoppingBag className="size-5" />}
          hint={`${num(need.reduce((s, r) => s + r.suggested_qty, 0))} قطعة مقترحة`}
        />
        <Stat
          label="أصناف نفدت"
          value={num(outCount)}
          tone="red"
          icon={<PackageX className="size-5" />}
          hint="عليها طلب خلال 90 يوماً"
        />
        <Stat
          label="تكلفة الشراء المقترح"
          value={money(suggestedCost)}
          tone="blue"
          icon={<Lightbulb className="size-5" />}
          hint="قبل الضريبة"
        />
        <Stat
          label="مخزون راكد +90 يوماً"
          value={money(dead.byBucket[90].cost)}
          tone="slate"
          icon={<Snowflake className="size-5" />}
          hint={`${num(dead.byBucket[90].count)} صنف · ${num(dead.byBucket[90].units)} قطعة`}
        />
      </div>

      <div
        className="mb-3 flex gap-1 rounded-xl bg-slate-100 p-1 sm:inline-flex"
        role="tablist"
      >
        {(
          [
            ["buy", "توصيات الشراء"],
            ["dead", "المخزون الراكد"],
          ] as const
        ).map(([k, label]) => (
          <button
            key={k}
            role="tab"
            aria-selected={tab === k}
            onClick={() => setTab(k)}
            className={cn(
              "flex-1 whitespace-nowrap rounded-lg px-4 py-2 text-sm font-medium",
              tab === k
                ? "bg-white text-slate-900 shadow-sm"
                : "text-slate-600",
            )}
          >
            {label}
          </button>
        ))}
      </div>

      <Card className="mb-4 p-3">
        <div className="flex flex-col gap-2 md:flex-row">
          <Input
            className="md:max-w-xs"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="بحث بالاسم، SKU، الباركود، المقاس، اللون"
          />
          {tab === "buy" && (
            <Select
              className="md:w-44"
              value={filter}
              onChange={(e) => {
                setFilter(e.target.value as Filter);
                setShown(SHOW_STEP);
              }}
              aria-label="الحالة"
            >
              {FILTERS.map(([k, label]) => (
                <option key={k} value={k}>
                  {label}
                </option>
              ))}
            </Select>
          )}
          <Select
            className="md:w-52"
            value={supplierFilter}
            onChange={(e) => setSupplierFilter(e.target.value)}
            aria-label="المورد"
          >
            <option value="">كل الموردين</option>
            {supplierOptions.map(([id, name]) => (
              <option key={id} value={id}>
                {name}
              </option>
            ))}
            <option value={NO_SUPPLIER}>بدون مورد سابق</option>
          </Select>
        </div>
      </Card>

      {tab === "buy" ? (
        buyRows.length === 0 ? (
          <Card>
            <EmptyState
              title={
                filter === "need"
                  ? "لا توجد أصناف تحتاج طلباً الآن"
                  : "لا توجد أصناف مطابقة"
              }
            >
              {filter === "need" &&
                "كل الأصناف التي لها مبيعات فوق نقطة إعادة الطلب بالإعدادات الحالية."}
            </EmptyState>
          </Card>
        ) : (
          <>
            {/* الجوال */}
            <ul className="space-y-3 md:hidden" data-testid="advisor-cards">
              {visibleBuy.map((r) => (
                <li
                  key={r.variant_id}
                  className="rounded-xl border border-slate-200 bg-white p-3"
                >
                  <div className="flex items-start gap-2">
                    <input
                      type="checkbox"
                      className="mt-1 size-5 shrink-0 accent-brand-700"
                      aria-label={`تحديد ${r.sku}`}
                      checked={selected[r.variant_id] !== undefined}
                      onChange={(e) => toggle(r, e.target.checked)}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="break-words font-semibold">
                        {r.product_name}
                      </p>
                      <p className="text-xs text-slate-500">
                        {variantLabel(r.size, r.color) || "—"} ·{" "}
                        <span dir="ltr">{r.sku}</span>
                      </p>
                    </div>
                    {status(r)}
                  </div>
                  <dl className="mt-3 grid grid-cols-3 gap-2 text-center text-xs">
                    <div className="rounded-lg bg-slate-50 p-2">
                      <dt className="text-slate-500">المخزون</dt>
                      <dd className="text-base font-bold tabular-nums">
                        {r.stock}
                        {r.on_order > 0 && (
                          <span className="text-xs font-normal text-sky-700">
                            {" "}
                            +{r.on_order}
                          </span>
                        )}
                      </dd>
                    </div>
                    <div className="rounded-lg bg-slate-50 p-2">
                      <dt className="text-slate-500">مباع 7/30/90</dt>
                      <dd className="text-base font-bold tabular-nums">
                        {r.sold_7}/{r.sold_30}/{r.sold_90}
                      </dd>
                    </div>
                    <div className="rounded-lg bg-slate-50 p-2">
                      <dt className="text-slate-500">يكفي (يوم)</dt>
                      <dd className="text-base font-bold tabular-nums">
                        {r.cover_days ?? "—"}
                      </dd>
                    </div>
                    <div className="rounded-lg bg-slate-50 p-2">
                      <dt className="text-slate-500">متوسط/يوم</dt>
                      <dd className="font-semibold tabular-nums">
                        {r.avg_daily}
                      </dd>
                    </div>
                    <div className="rounded-lg bg-slate-50 p-2">
                      <dt className="text-slate-500">نقطة الطلب</dt>
                      <dd className="font-semibold tabular-nums">
                        {r.reorder_point}
                      </dd>
                    </div>
                    <div className="rounded-lg bg-amber-50 p-2">
                      <dt className="text-amber-800">المقترح</dt>
                      <dd className="font-bold tabular-nums text-amber-900">
                        {r.suggested_qty}
                      </dd>
                    </div>
                  </dl>
                  <div className="mt-3 flex items-center gap-2">
                    <span className="min-w-0 flex-1 truncate text-xs text-slate-500">
                      {r.supplier_name ?? "بدون مورد سابق"} ·{" "}
                      {money(r.unit_cost)}
                    </span>
                    {selected[r.variant_id] !== undefined &&
                      qtyInput(r, "w-24")}
                  </div>
                  <details className="mt-2">
                    <summary className="cursor-pointer text-xs font-medium text-brand-800">
                      لماذا هذا الرقم؟
                    </summary>
                    <div className="mt-1">{why(r)}</div>
                  </details>
                </li>
              ))}
            </ul>

            {/* الكمبيوتر */}
            <Card className="hidden md:block">
              <Table>
                <thead>
                  <tr>
                    <th>
                      <input
                        type="checkbox"
                        className="size-4 accent-brand-700"
                        aria-label="تحديد الكل"
                        checked={allVisibleSelected}
                        onChange={(e) => toggleAllVisible(e.target.checked)}
                      />
                    </th>
                    <th>الصنف</th>
                    <th>الحالة</th>
                    <th>المخزون</th>
                    <th>مباع 7 / 30 / 90</th>
                    <th>متوسط/يوم</th>
                    <th>يكفي (يوم)</th>
                    <th>نقطة الطلب</th>
                    <th>المقترح</th>
                    <th>كمية الشراء</th>
                    <th>التكلفة</th>
                    <th>آخر مورد</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {visibleBuy.map((r) => (
                    <Fragment key={r.variant_id}>
                      <tr
                        className={cn(
                          selected[r.variant_id] !== undefined &&
                            "bg-brand-50/40",
                        )}
                      >
                        <td>
                          <input
                            type="checkbox"
                            className="size-4 accent-brand-700"
                            aria-label={`تحديد ${r.sku}`}
                            checked={selected[r.variant_id] !== undefined}
                            onChange={(e) => toggle(r, e.target.checked)}
                          />
                        </td>
                        <td className="max-w-64">
                          <p className="truncate font-medium">
                            {r.product_name}
                          </p>
                          <p className="text-xs text-slate-500">
                            {variantLabel(r.size, r.color) || "—"} ·{" "}
                            <span dir="ltr">{r.sku}</span>
                          </p>
                        </td>
                        <td>{status(r)}</td>
                        <td className="tabular-nums">
                          {r.stock}
                          {r.on_order > 0 && (
                            <span
                              className="text-xs text-sky-700"
                              title="في أوامر شراء مفتوحة"
                            >
                              {" "}
                              +{r.on_order}
                            </span>
                          )}
                        </td>
                        <td className="tabular-nums">
                          {r.sold_7} / {r.sold_30} / {r.sold_90}
                        </td>
                        <td className="tabular-nums">{r.avg_daily}</td>
                        <td className="tabular-nums">{r.cover_days ?? "—"}</td>
                        <td className="tabular-nums">{r.reorder_point}</td>
                        <td className="font-bold tabular-nums text-amber-800">
                          {r.suggested_qty || "—"}
                        </td>
                        <td>
                          {selected[r.variant_id] !== undefined ? (
                            qtyInput(r, "w-20")
                          ) : (
                            <span className="text-slate-300">—</span>
                          )}
                        </td>
                        <td className="tabular-nums">{money(r.unit_cost)}</td>
                        <td className="max-w-40 truncate text-slate-600">
                          {r.supplier_name ?? "—"}
                        </td>
                        <td>
                          <button
                            className="flex items-center gap-0.5 text-xs text-brand-800 hover:underline"
                            onClick={() => toggleExpanded(r.variant_id)}
                            aria-expanded={expanded.has(r.variant_id)}
                          >
                            لماذا؟{" "}
                            <ChevronDown
                              className={cn(
                                "size-3.5 transition",
                                expanded.has(r.variant_id) && "rotate-180",
                              )}
                            />
                          </button>
                        </td>
                      </tr>
                      {expanded.has(r.variant_id) && (
                        <tr className="bg-slate-50/70">
                          <td></td>
                          <td colSpan={12}>{why(r)}</td>
                        </tr>
                      )}
                    </Fragment>
                  ))}
                </tbody>
              </Table>
            </Card>
            {buyRows.length > shown && (
              <div className="mt-3 text-center">
                <Button
                  variant="outline"
                  onClick={() => setShown((n) => n + SHOW_STEP)}
                >
                  عرض المزيد ({num(buyRows.length - shown)})
                </Button>
              </div>
            )}
          </>
        )
      ) : (
        <>
          <div className="mb-3 grid grid-cols-3 gap-2">
            {DEAD_BUCKETS.map((d) => {
              const s = dead.byBucket[d];
              return (
                <button
                  key={d}
                  onClick={() => setDeadDays(d)}
                  aria-pressed={deadDays === d}
                  className={cn(
                    "rounded-xl border p-3 text-start transition",
                    deadDays === d
                      ? "border-brand-600 bg-brand-50 ring-1 ring-brand-600"
                      : "border-slate-200 bg-white hover:bg-slate-50",
                  )}
                >
                  <p className="text-xs text-slate-500 sm:text-sm">
                    بلا بيع +{d} يوماً
                  </p>
                  <p className="mt-1 break-words text-base font-bold tabular-nums sm:text-lg">
                    {money(s.cost)}
                  </p>
                  <p className="text-xs text-slate-500">
                    {num(s.count)} صنف · {num(s.units)} قطعة
                  </p>
                </button>
              );
            })}
          </div>
          <p className="mb-3 text-xs text-slate-500">
            القيمة بسعر التكلفة. قيمتها بسعر البيع:{" "}
            {money(dead.byBucket[deadDays].retail)}. فكّر في عرض أو خصم أو نقلها
            للواجهة قبل إعادة الشراء.
          </p>
          {dead.items.length === 0 ? (
            <Card>
              <EmptyState title={`لا توجد أصناف راكدة منذ ${deadDays} يوماً`} />
            </Card>
          ) : (
            <>
              <ul className="space-y-2 md:hidden">
                {dead.items.slice(0, shown).map((r) => (
                  <li
                    key={r.variant_id}
                    className="rounded-xl border border-slate-200 bg-white p-3"
                  >
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <p className="break-words font-semibold">
                          {r.product_name}
                        </p>
                        <p className="text-xs text-slate-500">
                          {variantLabel(r.size, r.color) || "—"} ·{" "}
                          <span dir="ltr">{r.sku}</span>
                        </p>
                      </div>
                      <Badge tone="slate">{r.idle_days} يوماً</Badge>
                    </div>
                    <p className="mt-2 flex flex-wrap justify-between gap-x-3 text-sm">
                      <span>المخزون {r.stock}</span>
                      <span className="font-semibold">
                        {money(r.stock * r.unit_cost)}
                      </span>
                    </p>
                    <p className="text-xs text-slate-500">
                      آخر بيع:{" "}
                      {r.last_sale_at ? dateOnly(r.last_sale_at) : "لم يُبع"}
                    </p>
                  </li>
                ))}
              </ul>
              <Card className="hidden md:block">
                <Table>
                  <thead>
                    <tr>
                      <th>الصنف</th>
                      <th>المخزون</th>
                      <th>أيام بلا بيع</th>
                      <th>آخر بيع</th>
                      <th>قيمة التكلفة</th>
                      <th>قيمة البيع</th>
                    </tr>
                  </thead>
                  <tbody>
                    {dead.items.slice(0, shown).map((r) => (
                      <tr key={r.variant_id}>
                        <td className="max-w-72">
                          <Link
                            href={`/products/${r.product_id}`}
                            className="block truncate font-medium hover:underline"
                          >
                            {r.product_name}
                          </Link>
                          <p className="text-xs text-slate-500">
                            {variantLabel(r.size, r.color) || "—"} ·{" "}
                            <span dir="ltr">{r.sku}</span>
                          </p>
                        </td>
                        <td className="tabular-nums">{r.stock}</td>
                        <td className="tabular-nums">{r.idle_days}</td>
                        <td>
                          {r.last_sale_at ? (
                            dateOnly(r.last_sale_at)
                          ) : (
                            <span className="text-slate-400">لم يُبع</span>
                          )}
                        </td>
                        <td className="font-semibold tabular-nums">
                          {money(r.stock * r.unit_cost)}
                        </td>
                        <td className="tabular-nums text-slate-600">
                          {money(r.stock * r.unit_price)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </Table>
              </Card>
              {dead.items.length > shown && (
                <div className="mt-3 text-center">
                  <Button
                    variant="outline"
                    onClick={() => setShown((n) => n + SHOW_STEP)}
                  >
                    عرض المزيد ({num(dead.items.length - shown)})
                  </Button>
                </div>
              )}
            </>
          )}
        </>
      )}

      {selectedRows.length > 0 && (
        <div
          className="sticky bottom-3 z-20 mt-4 rounded-2xl border border-slate-200 bg-white/95 px-4 py-3 shadow-lg backdrop-blur"
          data-testid="selection-bar"
        >
          <div className="flex flex-wrap items-center gap-2">
            <p className="min-w-0 flex-1 text-sm">
              <span className="font-semibold">{num(selectedRows.length)}</span>{" "}
              صنف · <span className="font-semibold">{num(selUnits)}</span> قطعة
              · <span className="font-semibold">{money(selCost)}</span>
            </p>
            <Button variant="ghost" onClick={() => setSelected({})}>
              إلغاء
            </Button>
            <Button onClick={openDraft}>
              <FilePlus2 className="size-4" /> مسودة طلب شراء
            </Button>
          </div>
        </div>
      )}

      <Modal
        open={draftOpen}
        onClose={() => !creating && setDraftOpen(false)}
        title="تحويل إلى مسودة أمر شراء"
        size="lg"
        footer={
          <>
            <Button
              variant="ghost"
              onClick={() => setDraftOpen(false)}
              disabled={creating}
            >
              إلغاء
            </Button>
            <Button onClick={createDrafts} disabled={creating}>
              {creating ? "جاري الإنشاء..." : "إنشاء المسودة"}
            </Button>
          </>
        }
      >
        <p className="mb-3 text-sm text-slate-600">
          تُنشأ مسودة لكل مورد بتكلفة آخر شراء لكل صنف. المخزون لا يتغير الآن.
          يمكنك تعديل المسودة ثم تغيير حالتها إلى «مطلوب» واستلامها من شاشة
          المشتريات.
        </p>
        <div className="space-y-3">
          {groups.map((g) => {
            const units = g.rows.reduce(
              (s, r) => s + (Number(selected[r.variant_id]) || 0),
              0,
            );
            const cost = g.rows.reduce(
              (s, r) => s + (Number(selected[r.variant_id]) || 0) * r.unit_cost,
              0,
            );
            return (
              <div
                key={g.key}
                className="rounded-xl border border-slate-200 p-3"
              >
                <div className="flex flex-wrap items-end gap-2">
                  <Field
                    label={
                      g.key === NO_SUPPLIER
                        ? "المورد (لم يُشترَ من مورد سابقاً)"
                        : "المورد"
                    }
                    className="min-w-48 flex-1"
                  >
                    <Select
                      value={groupSupplier[g.key] ?? ""}
                      onChange={(e) =>
                        setGroupSupplier({
                          ...groupSupplier,
                          [g.key]: e.target.value,
                        })
                      }
                    >
                      <option value="">— اختر المورد —</option>
                      {suppliers.map((s) => (
                        <option key={s.id} value={s.id}>
                          {s.name}
                        </option>
                      ))}
                    </Select>
                  </Field>
                  {(() => {
                    const first = g.rows.map((r) => advice[r.variant_id]).find(Boolean);
                    if (!first) return null;
                    return (
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => setAdviceOpen(adviceOpen === g.key ? null : g.key)}
                      >
                        <HelpCircle className="size-4" /> المقترح: {first.supplier_name}
                      </Button>
                    );
                  })()}
                  <p className="pb-2 text-sm text-slate-600">
                    {num(g.rows.length)} صنف · {num(units)} قطعة ·{" "}
                    <span className="font-semibold text-slate-900">
                      {money(cost)}
                    </span>
                  </p>
                </div>
                {adviceOpen === g.key && (
                  <ul className="mt-2 space-y-1 rounded-lg bg-slate-50 p-2 text-xs leading-relaxed text-slate-700">
                    {g.rows.filter((r) => advice[r.variant_id]).map((r) => (
                      <li key={r.variant_id}>
                        <b>{r.sku}:</b> {advice[r.variant_id].reason}
                      </li>
                    ))}
                  </ul>
                )}
                <ul className="mt-2 max-h-32 overflow-y-auto text-xs text-slate-500 scrollbar-thin">
                  {g.rows.map((r) => (
                    <li
                      key={r.variant_id}
                      className="flex justify-between gap-2 py-0.5"
                    >
                      <span className="truncate">
                        {r.product_name} —{" "}
                        {variantLabel(r.size, r.color) || r.sku}
                      </span>
                      <span className="shrink-0 tabular-nums">
                        × {selected[r.variant_id]}
                      </span>
                    </li>
                  ))}
                </ul>
              </div>
            );
          })}
          {suppliers.length === 0 && (
            <p className="text-sm text-red-600">
              لا يوجد موردون نشطون.{" "}
              <Link href="/suppliers" className="underline">
                أضف مورداً
              </Link>{" "}
              أولاً.
            </p>
          )}
        </div>
      </Modal>
    </div>
  );
}
