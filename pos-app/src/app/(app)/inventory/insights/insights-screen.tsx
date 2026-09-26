"use client";

import { AlertTriangle, Grid3x3, Snowflake } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Badge, Button, Card, EmptyState, Loading, PageHeader, Select, Stat, Table, cn, useToast } from "@/components/ui";
import { dateOnly, errorMessage, money, num } from "@/lib/format";
import { ANOMALY_KINDS, DEAD_ACTIONS, fetchLocations, n, rpcAll, type Anomaly, type DeadRow, type Gap, type Location } from "@/lib/inventory";

type Tab = "gaps" | "anomalies" | "dead";
const BUCKETS = [30, 60, 90, 180] as const;
const SEVERITY = { high: { label: "عالٍ", tone: "red" }, medium: { label: "متوسط", tone: "amber" }, low: { label: "منخفض", tone: "slate" } } as const;

export function InsightsScreen() {
  const toast = useToast();
  const [tab, setTab] = useState<Tab>("gaps");
  const [loc, setLoc] = useState("");
  const [locations, setLocations] = useState<Location[]>([]);
  const [gaps, setGaps] = useState<Gap[] | null>(null);
  const [anomalies, setAnomalies] = useState<Anomaly[] | null>(null);
  const [dead, setDead] = useState<DeadRow[] | null>(null);
  const [bucket, setBucket] = useState<(typeof BUCKETS)[number]>(90);
  const [gapKind, setGapKind] = useState<"" | Gap["gap_kind"]>("");

  const load = useCallback(async () => {
    setGaps(null);
    setDead(null);
    setAnomalies(null);
    try {
      const p = { p_location: loc || null };
      const [g, a, d] = await Promise.all([rpcAll<Gap>("size_color_gaps", p), rpcAll<Anomaly>("inventory_anomalies"), rpcAll<DeadRow>("dead_stock_plan", p)]);
      setGaps(g);
      setAnomalies(a);
      setDead(d.map((r) => ({ ...r, cost_value: n(r.cost_value), retail_value: n(r.retail_value) })));
    } catch (e) {
      toast(errorMessage(e), "error");
      setGaps([]);
      setAnomalies([]);
      setDead([]);
    }
  }, [loc, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);
  useEffect(() => {
    fetchLocations()
      .then(setLocations)
      .catch(() => setLocations([]));
  }, []);

  const anomaliesShown = useMemo(() => (anomalies ?? []).filter((a) => !loc || !a.location_id || a.location_id === loc), [anomalies, loc]);
  const gapsShown = useMemo(
    () => (gaps ?? []).filter((g) => !gapKind || g.gap_kind === gapKind).sort((a, b) => Number(b.priority) - Number(a.priority)),
    [gaps, gapKind],
  );
  const deadShown = useMemo(() => (dead ?? []).filter((d) => d.idle_days >= bucket).sort((a, b) => b.cost_value - a.cost_value), [dead, bucket]);
  const deadTotals = (days: number) => {
    const list = (dead ?? []).filter((d) => d.idle_days >= days);
    return { qty: list.reduce((s, d) => s + d.on_hand, 0), cost: list.reduce((s, d) => s + d.cost_value, 0) };
  };

  const tabs: Array<[Tab, string, typeof Grid3x3, number | null]> = [
    ["gaps", "المقاسات والألوان الناقصة", Grid3x3, gaps?.length ?? null],
    ["anomalies", "المخزون الشاذ", AlertTriangle, anomaliesShown.length],
    ["dead", "المخزون الراكد", Snowflake, dead?.length ?? null],
  ];

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="تحليلات المخزون"
        subtitle="ما الناقص، وما الغريب، وما الراكد — مع السبب لكل سطر"
        actions={
          <>
            <Select aria-label="الموقع" className="w-auto min-w-40" value={loc} onChange={(e) => setLoc(e.target.value)}>
              <option value="">كل المواقع</option>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </Select>
            <Link href="/decisions">
              <Button>مركز القرارات</Button>
            </Link>
          </>
        }
      />

      <div className="mb-4 flex gap-1 overflow-x-auto rounded-xl bg-slate-100 p-1 scrollbar-thin">
        {tabs.map(([k, label, Icon, count]) => (
          <button
            key={k}
            type="button"
            onClick={() => setTab(k)}
            className={cn(
              "flex shrink-0 items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium",
              tab === k ? "bg-white text-slate-900 shadow-sm" : "text-slate-600 hover:text-slate-900",
            )}
          >
            <Icon className="size-4" /> {label}
            {count !== null && <Badge>{num(count)}</Badge>}
          </button>
        ))}
      </div>

      {tab === "gaps" && (
        <Card>
          <div className="flex flex-wrap gap-2 border-b border-slate-100 p-3">
            <Select aria-label="نوع النقص" className="w-auto" value={gapKind} onChange={(e) => setGapKind(e.target.value as typeof gapKind)}>
              <option value="">الكل</option>
              <option value="out_of_stock">نفد من الموقع</option>
              <option value="not_created">تركيبة غير مُنشأة</option>
            </Select>
          </div>
          {gaps === null ? (
            <Loading />
          ) : gapsShown.length === 0 ? (
            <EmptyState title="لا توجد مقاسات أو ألوان ناقصة" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>الموديل</th>
                  <th>المقاس / اللون</th>
                  <th>الموقع</th>
                  <th>النوع</th>
                  <th>مبيعات 90 يوماً</th>
                  <th>متوفر في مواقع أخرى</th>
                  <th>السبب</th>
                </tr>
              </thead>
              <tbody>
                {gapsShown.slice(0, 500).map((g, i) => (
                  <tr key={`${g.location_id}-${g.product_id}-${g.size}-${g.color}-${i}`}>
                    <td className="font-medium">{g.product_name}</td>
                    <td>{[g.size, g.color].filter(Boolean).join(" / ") || "-"}</td>
                    <td>{g.location_name}</td>
                    <td>
                      <Badge tone={g.gap_kind === "out_of_stock" ? "red" : "slate"}>{g.gap_kind === "out_of_stock" ? "نفد" : "غير مُنشأ"}</Badge>
                    </td>
                    <td>
                      {num(g.variant_sold_90)} <span className="text-xs text-slate-500">(الموديل {num(g.model_sold_90)})</span>
                    </td>
                    <td>{g.available_elsewhere > 0 ? <Badge tone="blue">{num(g.available_elsewhere)}</Badge> : "-"}</td>
                    <td className="max-w-md whitespace-normal text-xs text-slate-600">{g.reason}</td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "anomalies" && (
        <Card>
          {anomalies === null ? (
            <Loading />
          ) : anomaliesShown.length === 0 ? (
            <EmptyState title="لا توجد حالات شاذة" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <th>الأهمية</th>
                  <th>النوع</th>
                  <th>الصنف</th>
                  <th>الموقع</th>
                  <th>الكمية</th>
                  <th>القيمة</th>
                  <th>السبب</th>
                </tr>
              </thead>
              <tbody>
                {anomaliesShown.map((a, i) => (
                  <tr key={`${a.kind}-${a.variant_id}-${a.location_id}-${i}`}>
                    <td>
                      <Badge tone={SEVERITY[a.severity]?.tone ?? "slate"}>{SEVERITY[a.severity]?.label ?? a.severity}</Badge>
                    </td>
                    <td>{ANOMALY_KINDS[a.kind] ?? a.kind}</td>
                    <td>
                      {a.product_name ? (
                        <>
                          <p className="font-medium">{a.product_name}</p>
                          <p className="text-xs text-slate-500">
                            {a.variant_label ?? ""} <span className="ltr-nums">{a.sku}</span>
                          </p>
                        </>
                      ) : (
                        "-"
                      )}
                    </td>
                    <td>{a.location_name ?? "-"}</td>
                    <td>{a.qty ?? "-"}</td>
                    <td>{a.value !== null ? money(a.value) : "-"}</td>
                    <td className="max-w-md whitespace-normal text-xs text-slate-600">
                      {a.reason}
                      {a.ref_id && (a.kind === "transfer_discrepancy" || a.kind === "stale_transit") && (
                        <Link className="ms-1 text-brand-700 hover:underline" href={`/transfers/${a.ref_id}`}>
                          فتح التحويل
                        </Link>
                      )}
                      {a.ref_id && a.kind === "count_variance" && (
                        <Link className="ms-1 text-brand-700 hover:underline" href={`/inventory/counts/${a.ref_id}`}>
                          فتح الجرد
                        </Link>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "dead" && (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
            {BUCKETS.map((b) => {
              const t = deadTotals(b);
              return (
                <button key={b} type="button" onClick={() => setBucket(b)} className="text-start">
                  <Stat label={`بلا بيع ${b}+ يوماً`} value={`${num(t.qty)} قطعة`} hint={money(t.cost)} tone={bucket === b ? "blue" : "slate"} />
                </button>
              );
            })}
          </div>
          <Card>
            {dead === null ? (
              <Loading />
            ) : deadShown.length === 0 ? (
              <EmptyState title="لا يوجد مخزون راكد في هذه الفترة" />
            ) : (
              <Table>
                <thead>
                  <tr>
                    <th>الصنف</th>
                    <th>الموقع</th>
                    <th>الكمية</th>
                    <th>بلا بيع</th>
                    <th>آخر بيع</th>
                    <th>التكلفة</th>
                    <th>الاقتراح</th>
                    <th>السبب</th>
                  </tr>
                </thead>
                <tbody>
                  {deadShown.slice(0, 500).map((d) => (
                    <tr key={`${d.location_id}-${d.variant_id}`}>
                      <td>
                        <p className="font-medium">{d.product_name}</p>
                        <p className="text-xs text-slate-500">
                          {d.variant_label ?? ""} <span className="ltr-nums">{d.sku}</span>
                        </p>
                      </td>
                      <td>{d.location_name}</td>
                      <td>{num(d.on_hand)}</td>
                      <td>{num(d.idle_days)} يوم</td>
                      <td className="ltr-nums text-xs">{d.last_sale_at ? dateOnly(d.last_sale_at) : "لم يُبع"}</td>
                      <td>{money(d.cost_value)}</td>
                      <td>
                        <Badge tone={d.action === "transfer" ? "blue" : d.action === "markdown" ? "red" : d.action === "promo" ? "violet" : "slate"}>
                          {DEAD_ACTIONS[d.action]}
                          {d.action === "transfer" && d.best_location_name ? ` ← ${d.best_location_name}` : ""}
                        </Badge>
                      </td>
                      <td className="max-w-md whitespace-normal text-xs text-slate-600">{d.reason}</td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            )}
          </Card>
          <p className="mt-3 text-xs text-slate-500">الاقتراحات إرشادية فقط — لا يُطبق أي خصم تلقائياً.</p>
        </>
      )}
    </div>
  );
}
