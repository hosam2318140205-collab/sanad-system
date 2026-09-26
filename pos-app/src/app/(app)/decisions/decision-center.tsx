"use client";

import { ArrowLeft, ChevronDown, FilePlus2, HelpCircle, RefreshCw, Truck } from "lucide-react";
import Link from "next/link";
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Stat, Table, cn, useToast } from "@/components/ui";
import { errorMessage, money, num } from "@/lib/format";
import { DECISION_ACTIONS, fetchLocations, n, newRef, rpcAll, type Decision, type DecisionAction, type Location } from "@/lib/inventory";
import { supabase } from "@/lib/supabase/client";
import type { Supplier } from "@/lib/types";

const ORDER: DecisionAction[] = ["transfer", "order", "markdown", "promo", "review"];
const key = (d: Decision) => `${d.action}|${d.variant_id}|${d.from_location ?? ""}|${d.to_location ?? ""}`;

// أسماء حقول «لماذا؟» كما يعيدها decision_center
const WHY_LABELS: Record<string, string> = {
  on_hand: "الموجود",
  available: "المتاح للبيع",
  in_transit: "القادم (بالطريق + معتمد)",
  sold_7: "مبيعات 7 أيام",
  sold_30: "مبيعات 30 يوماً",
  sold_60: "مبيعات 60 يوماً",
  sold_90: "مبيعات 90 يوماً",
  avg_daily: "متوسط البيع اليومي",
  reorder_point: "نقطة إعادة الطلب",
  target: "المستهدف",
  need: "الاحتياج",
  surplus: "الفائض",
  idle_days: "أيام بلا بيع",
  cost_value: "القيمة بالتكلفة",
  retail_value: "القيمة بالبيع",
};

function WhyTable({ why }: { why: Record<string, unknown> }) {
  const side = (title: string, v: unknown) => {
    if (!v || typeof v !== "object") return null;
    const o = v as Record<string, unknown>;
    return (
      <div className="min-w-0 rounded-lg border border-slate-200 bg-white p-3">
        <p className="mb-2 font-semibold text-slate-800">
          {title}: {String(o.name ?? "")}
        </p>
        <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
          {Object.entries(o)
            .filter(([k]) => k !== "name" && WHY_LABELS[k])
            .map(([k, val]) => (
              <Fragment key={k}>
                <dt className="text-slate-500">{WHY_LABELS[k]}</dt>
                <dd className="ltr-nums font-medium text-slate-900">{String(val ?? "-")}</dd>
              </Fragment>
            ))}
        </dl>
      </div>
    );
  };
  const flat = Object.entries(why).filter(([k, v]) => WHY_LABELS[k] && (typeof v !== "object" || v === null));
  return (
    <div className="grid gap-3 md:grid-cols-2">
      {side("من", why.from)}
      {side("إلى", why.to)}
      {flat.length > 0 && (
        <dl className="grid grid-cols-2 gap-x-4 gap-y-1 rounded-lg border border-slate-200 bg-white p-3 text-xs">
          {flat.map(([k, v]) => (
            <Fragment key={k}>
              <dt className="text-slate-500">{WHY_LABELS[k]}</dt>
              <dd className="ltr-nums font-medium text-slate-900">{String(v ?? "-")}</dd>
            </Fragment>
          ))}
        </dl>
      )}
      {"covered_by_transfer" in why && (
        <p className="text-xs text-slate-600 md:col-span-2">
          مغطى بالنقل: {String(why.covered_by_transfer)} · متوفر في مواقع أخرى تحتاجه: {String(why.available_elsewhere ?? 0)}
        </p>
      )}
    </div>
  );
}

export function DecisionCenter() {
  const toast = useToast();
  const [rows, setRows] = useState<Decision[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [params, setParams] = useState({ lead: "7", cover: "30", safety: "7" });
  const [tab, setTab] = useState<"all" | DecisionAction>("all");
  const [loc, setLoc] = useState("");
  const [locations, setLocations] = useState<Location[]>([]);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [draftOpen, setDraftOpen] = useState(false);
  const transferRef = useRef(newRef());

  const run = useCallback(async () => {
    setLoading(true);
    try {
      const data = await rpcAll<Decision>("decision_center", {
        p_lead_days: Number(params.lead) || 0,
        p_cover_days: Number(params.cover) || 30,
        p_safety_days: Number(params.safety) || 0,
      });
      setRows(data.map((d) => ({ ...d, qty: n(d.qty), cost_value: n(d.cost_value), retail_value: n(d.retail_value) })));
      setSelected(new Set());
      transferRef.current = newRef();
    } catch (e) {
      toast(errorMessage(e), "error");
      setRows((r) => r ?? []);
    } finally {
      setLoading(false);
    }
  }, [params, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    run();
    fetchLocations()
      .then(setLocations)
      .catch(() => setLocations([]));
    supabase()
      .from("suppliers")
      .select("*")
      .eq("is_active", true)
      .order("name")
      .then(({ data }) => setSuppliers((data ?? []) as Supplier[]));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const inLoc = useCallback((d: Decision) => !loc || d.from_location === loc || d.to_location === loc, [loc]);
  const shown = useMemo(
    () => (rows ?? []).filter((d) => (tab === "all" || d.action === tab) && inLoc(d)).sort((a, b) => a.priority - b.priority || b.cost_value - a.cost_value),
    [rows, tab, inLoc],
  );
  const summary = useMemo(() => {
    const s = Object.fromEntries(ORDER.map((a) => [a, { lines: 0, qty: 0, cost: 0, retail: 0 }])) as Record<DecisionAction, { lines: number; qty: number; cost: number; retail: number }>;
    for (const d of rows ?? []) {
      if (!inLoc(d)) continue;
      const x = s[d.action];
      x.lines++;
      x.qty += d.qty;
      x.cost += d.cost_value;
      x.retail += d.retail_value;
    }
    return s;
  }, [rows, inLoc]);

  const selectedRows = (rows ?? []).filter((d) => selected.has(key(d)));
  const selTransfers = selectedRows.filter((d) => d.action === "transfer");
  const selOrders = selectedRows.filter((d) => d.action === "order");

  const toggle = (set: Set<string>, k: string) => {
    const next = new Set(set);
    if (next.has(k)) next.delete(k);
    else next.add(k);
    return next;
  };

  const createTransfers = async () => {
    setBusy(true);
    const { data, error } = await supabase().rpc("create_transfers_from_decisions", {
      p_lines: selTransfers.map((d) => ({ from: d.from_location, to: d.to_location, variant_id: d.variant_id, qty: d.qty })),
      p_notes: "من مركز القرارات",
      p_client_ref: transferRef.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    const list = (data ?? []) as Array<{ transfer_no: string; status: string }>;
    toast(`تم إنشاء ${list.length} تحويل: ${list.map((t) => t.transfer_no).join("، ")}`);
    run();
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="مركز قرارات المخزون"
        subtitle="انقل قبل أن تشتري: كل توصية بالأرقام — من أين، إلى أين، كم، ولماذا"
        actions={
          <Link href="/transfers">
            <Button variant="outline">
              <Truck className="size-4" /> التحويلات
            </Button>
          </Link>
        }
      />

      <Card className="mb-4 p-4">
        <div className="flex flex-wrap items-end gap-3">
          <Field label="مدة التوريد (يوم)">
            <Input type="number" min={0} className="w-28" value={params.lead} onChange={(e) => setParams({ ...params, lead: e.target.value })} />
          </Field>
          <Field label="التغطية (يوم)">
            <Input type="number" min={1} className="w-28" value={params.cover} onChange={(e) => setParams({ ...params, cover: e.target.value })} />
          </Field>
          <Field label="أمان (يوم)">
            <Input type="number" min={0} className="w-28" value={params.safety} onChange={(e) => setParams({ ...params, safety: e.target.value })} />
          </Field>
          <Field label="الموقع">
            <Select aria-label="تصفية الموقع" className="w-auto min-w-40" value={loc} onChange={(e) => setLoc(e.target.value)}>
              <option value="">كل المواقع</option>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </Select>
          </Field>
          <Button variant="outline" onClick={run} loading={loading}>
            <RefreshCw className="size-4" /> إعادة الحساب
          </Button>
        </div>
      </Card>

      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-5">
        {ORDER.map((a) => (
          <button key={a} type="button" onClick={() => setTab(tab === a ? "all" : a)} className="text-start">
            <Stat
              label={`${DECISION_ACTIONS[a].label} (${num(summary[a].lines)})`}
              value={`${num(summary[a].qty)} قطعة`}
              hint={a === "review" ? "تحتاج تدقيق" : `تكلفة ${money(summary[a].cost)} · بيع ${money(summary[a].retail)}`}
              tone={tab === a ? "blue" : "slate"}
            />
          </button>
        ))}
      </div>

      {(selTransfers.length > 0 || selOrders.length > 0) && (
        <Card className="sticky top-2 z-10 mb-4 flex flex-wrap items-center gap-2 p-3">
          <span className="text-sm text-slate-600">المحدد: {num(selectedRows.length)}</span>
          {selTransfers.length > 0 && (
            <Button onClick={createTransfers} loading={busy}>
              <Truck className="size-4" /> إنشاء التحويلات ({num(selTransfers.length)})
            </Button>
          )}
          {selOrders.length > 0 && (
            <Button variant="secondary" onClick={() => setDraftOpen(true)}>
              <FilePlus2 className="size-4" /> مسودة شراء ({num(selOrders.length)})
            </Button>
          )}
          <Button variant="ghost" onClick={() => setSelected(new Set())}>
            إلغاء التحديد
          </Button>
        </Card>
      )}

      <Card>
        {loading && !rows ? (
          <Loading label="جاري تحليل المبيعات والأرصدة في كل المواقع..." />
        ) : shown.length === 0 ? (
          <EmptyState title="لا توجد توصيات">المخزون متوازن حسب الإعدادات الحالية.</EmptyState>
        ) : (
          <Table>
            <thead>
              <tr>
                <th></th>
                <th>القرار</th>
                <th>الصنف</th>
                <th>من ← إلى</th>
                <th>الكمية</th>
                <th>التكلفة</th>
                <th>البيع</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {shown.map((d) => {
                const k = key(d);
                const actionable = d.action === "transfer" || d.action === "order";
                return (
                  <Fragment key={k}>
                    <tr className={cn(selected.has(k) && "bg-sky-50/60")}>
                      <td>
                        {actionable && (
                          <input
                            type="checkbox"
                            aria-label={`تحديد ${d.sku}`}
                            className="size-4 accent-brand-700"
                            checked={selected.has(k)}
                            onChange={() => setSelected((s) => toggle(s, k))}
                          />
                        )}
                      </td>
                      <td>
                        <Badge tone={DECISION_ACTIONS[d.action].tone}>{DECISION_ACTIONS[d.action].label}</Badge>
                      </td>
                      <td>
                        <p className="font-medium">{d.product_name}</p>
                        <p className="text-xs text-slate-500">
                          {d.variant_label ?? ""} <span className="ltr-nums">{d.sku}</span>
                        </p>
                      </td>
                      <td className="text-sm">
                        {d.from_name || d.to_name ? (
                          <span className="inline-flex items-center gap-1">
                            {d.from_name ?? (d.action === "order" ? "المورد" : "")}
                            {d.to_name && <ArrowLeft className="size-3.5 text-slate-400" />}
                            {d.to_name ?? ""}
                          </span>
                        ) : (
                          "-"
                        )}
                      </td>
                      <td className="font-semibold">{d.qty ? num(d.qty) : "-"}</td>
                      <td>{d.cost_value ? money(d.cost_value) : "-"}</td>
                      <td>{d.retail_value ? money(d.retail_value) : "-"}</td>
                      <td>
                        <Button size="sm" variant="ghost" onClick={() => setOpen((s) => toggle(s, k))} aria-expanded={open.has(k)}>
                          <HelpCircle className="size-4" /> لماذا؟
                          <ChevronDown className={cn("size-4 transition-transform", open.has(k) && "rotate-180")} />
                        </Button>
                      </td>
                    </tr>
                    {open.has(k) && (
                      <tr className="bg-slate-50">
                        <td colSpan={8} className="whitespace-normal">
                          <p className="mb-3 max-w-3xl text-sm leading-relaxed text-slate-800">{d.reason}</p>
                          {d.why && <WhyTable why={d.why} />}
                        </td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>
      <p className="mt-3 text-xs text-slate-500">
        لا يُطبق أي خصم أو تحويل تلقائياً. التحويل يُنشأ معتمداً (إلا عند تفعيل فصل المهام) ويُحجز من المتاح، فلا يُقترح مرة أخرى ولا يُشترى ما يغطيه.
      </p>

      {draftOpen && (
        <DraftDialog
          orders={selOrders}
          suppliers={suppliers}
          onClose={() => setDraftOpen(false)}
          onDone={() => {
            setDraftOpen(false);
            run();
          }}
        />
      )}
    </div>
  );
}

function DraftDialog({ orders, suppliers, onClose, onDone }: { orders: Decision[]; suppliers: Supplier[]; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const groups = useMemo(() => {
    const m = new Map<string, { name: string; lines: Decision[] }>();
    for (const d of orders) {
      const k = d.to_location ?? "";
      if (!m.has(k)) m.set(k, { name: d.to_name ?? "", lines: [] });
      m.get(k)!.lines.push(d);
    }
    return [...m];
  }, [orders]);
  const [supplier, setSupplier] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);

  const create = async () => {
    if (groups.some(([k]) => !supplier[k])) return toast("اختر المورد لكل موقع", "error");
    setBusy(true);
    try {
      for (const [k, g] of groups) {
        const { error } = await supabase().rpc("create_purchase_draft_at", {
          p_supplier_id: supplier[k],
          p_location: k,
          p_items: g.lines.map((d) => ({ variant_id: d.variant_id, qty: d.qty })),
        });
        if (error) throw error;
      }
      toast(`تم إنشاء ${groups.length} مسودة شراء — راجعها من المشتريات`);
      onDone();
    } catch (e) {
      toast(errorMessage(e), "error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open
      onClose={onClose}
      title="مسودات شراء حسب موقع الاستلام"
      size="md"
      footer={
        <Button onClick={create} loading={busy}>
          إنشاء المسودات
        </Button>
      }
    >
      <div className="space-y-4">
        {groups.map(([k, g]) => (
          <div key={k} className="rounded-lg border border-slate-200 p-3">
            <p className="mb-2 font-medium">
              {g.name} — {num(g.lines.reduce((s, d) => s + d.qty, 0))} قطعة · {money(g.lines.reduce((s, d) => s + d.cost_value, 0))}
            </p>
            <Select aria-label={`مورد ${g.name}`} value={supplier[k] ?? ""} onChange={(e) => setSupplier((s) => ({ ...s, [k]: e.target.value }))}>
              <option value="">اختر المورد</option>
              {suppliers.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </Select>
          </div>
        ))}
        <p className="text-xs text-slate-500">تُنشأ كمسودات فقط. الاستلام يضيف المخزون إلى الموقع المحدد في أمر الشراء.</p>
      </div>
    </Modal>
  );
}
