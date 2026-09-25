"use client";

import { ArrowRight, CheckCircle2, RotateCcw, ScanBarcode, Send, XCircle } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CameraScanButton, CameraScanner, type ScanOutcome } from "@/components/camera-scanner";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, Checkbox, ConfirmDialog, Field, Input, Loading, Modal, PageHeader, Select, Stat, Table, Textarea, cn, useToast } from "@/components/ui";
import { fetchAllRows, normalize } from "@/lib/catalog";
import { dateTime, errorMessage, money, num, variantLabel } from "@/lib/format";
import { newRef } from "@/lib/inventory";
import { supabase } from "@/lib/supabase/client";
import type { StockCount } from "@/lib/types";

// جرد أعمى: الكاشير لا يقرأ expected_qty (العمود غير ممنوح له). المدير يرى المراجعة من count_review
interface Item {
  id: string;
  variant_id: string;
  counted_qty: number | null;
  counted_at: string | null;
  variant: { sku: string; barcode: string | null; size: string | null; color: string | null; product: { name: string } };
}

interface Review {
  variant_id: string;
  snapshot_qty: number;
  moves_after_snapshot: number;
  expected_qty: number;
  counted_qty: number | null;
  variance: number | null;
  unit_cost: number;
  variance_value: number | null;
  current_qty: number;
}

type Count = StockCount & { location: { name: string } | null };

export function CountSheet({ id }: { id: string }) {
  const toast = useToast();
  const { isManager } = useSession();
  const [count, setCount] = useState<Count | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [review, setReview] = useState<Record<string, Review>>({});
  const [scan, setScan] = useState("");
  const [q, setQ] = useState("");
  const [view, setView] = useState<"all" | "uncounted" | "diff">("all");
  const [confirm, setConfirm] = useState<"submit" | "reopen" | null>(null);
  const [approveOpen, setApproveOpen] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [lastScanned, setLastScanned] = useState<string | null>(null);
  const scanRef = useRef<HTMLInputElement>(null);
  const [showCamera, setShowCamera] = useState(false);

  const loadReview = useCallback(async () => {
    if (!isManager) return;
    const { data, error } = await supabase().rpc("count_review", { p_count_id: id }).range(0, 99999);
    if (error) return toast(errorMessage(error), "error");
    setReview(Object.fromEntries(((data ?? []) as Review[]).map((r) => [r.variant_id, r])));
  }, [id, isManager, toast]);

  const load = useCallback(async () => {
    const db = supabase();
    const [{ data: c }, its] = await Promise.all([
      db.from("stock_counts").select("*, location:locations(name)").eq("id", id).single(),
      fetchAllRows<Item>((from, to) =>
        db
          .from("stock_count_items")
          .select("id, variant_id, counted_qty, counted_at, variant:product_variants(sku, barcode, size, color, product:products(name))")
          .eq("count_id", id)
          .order("id")
          .range(from, to),
      ),
    ]);
    setCount(c as Count);
    setItems(its.sort((a, b) => a.variant.product.name.localeCompare(b.variant.product.name, "ar")));
    await loadReview();
  }, [id, loadReview]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const editable = count?.status === "open";
  const legacy = count !== null && !count.location_id;

  // كل مسحة تُرسل للخادم بمرجع فريد: إعادة الإرسال لا تُحسب مرتين، ومسحات الأجهزة المختلفة تُجمع
  const applyResult = (variantId: string, counted: number | null) => {
    setItems((its) => its.map((i) => (i.variant_id === variantId ? { ...i, counted_qty: counted } : i)));
  };

  const sendScan = async (code: string, qty = 1): Promise<ScanOutcome> => {
    const { data, error } = await supabase().rpc("record_count_scan", { p_count_id: id, p_code: code, p_qty: qty, p_client_ref: newRef() });
    if (error) return { ok: false, message: errorMessage(error) };
    const r = data as { variant_id: string; name: string; label: string | null; counted: number };
    if (!items.some((i) => i.variant_id === r.variant_id)) await load();
    else applyResult(r.variant_id, r.counted);
    setLastScanned(r.variant_id);
    return { ok: true, message: `${r.name}${r.label ? ` (${r.label})` : ""} — المعدود ${r.counted}` };
  };

  const onScan = async () => {
    const code = scan.trim();
    if (!code) return;
    setScan("");
    const outcome = await sendScan(code);
    if (!outcome.ok) toast(outcome.message, "error");
    scanRef.current?.focus();
  };

  const setQty = async (item: Item, qty: number) => {
    const { data, error } = await supabase().rpc("set_count_qty", { p_count_id: id, p_variant: item.variant_id, p_qty: qty, p_client_ref: newRef() });
    if (error) {
      toast(errorMessage(error), "error");
      return load();
    }
    applyResult(item.variant_id, (data as { counted: number }).counted);
  };

  const filtered = useMemo(() => {
    const term = normalize(q);
    return items.filter((i) => {
      if (view === "uncounted" && i.counted_qty !== null) return false;
      if (view === "diff") {
        const r = review[i.variant_id];
        if (i.counted_qty === null || !r || i.counted_qty === r.expected_qty) return false;
      }
      if (!term) return true;
      return normalize(i.variant.product.name).includes(term) || i.variant.sku.toLowerCase().includes(term) || i.variant.barcode?.includes(term);
    });
  }, [items, q, view, review]);

  const counted = items.filter((i) => i.counted_qty !== null).length;
  const variance = useMemo(() => {
    let shortage = 0;
    let surplus = 0;
    let value = 0;
    for (const i of items) {
      const r = review[i.variant_id];
      if (!r || i.counted_qty === null) continue;
      const d = i.counted_qty - r.expected_qty;
      if (d < 0) shortage += d;
      else surplus += d;
      value += d * Number(r.unit_cost);
    }
    return { shortage, surplus, value };
  }, [items, review]);

  const rpc = async (fn: string, args: Record<string, unknown>, ok: string) => {
    setBusy(true);
    const { data, error } = await supabase().rpc(fn, args);
    setBusy(false);
    if (error) {
      toast(errorMessage(error), "error");
      return null;
    }
    toast(ok);
    await load();
    return data;
  };

  if (!count) return <Loading />;
  const statusBadge = {
    open: <Badge tone="blue">مفتوح للعدّ</Badge>,
    submitted: <Badge tone="amber">بانتظار اعتماد المدير</Badge>,
    applied: <Badge tone="green">معتمد</Badge>,
    cancelled: <Badge tone="slate">ملغي</Badge>,
  }[count.status];

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title={`جرد ${count.count_no}`}
        subtitle={[count.location?.name ?? "جرد إجمالي قديم", count.notes].filter(Boolean).join(" — ")}
        actions={
          <>
            <Link href="/inventory/counts">
              <Button variant="ghost">
                <ArrowRight className="size-4" /> رجوع
              </Button>
            </Link>
            {statusBadge}
            {editable && !legacy && (
              <Button variant="outline" onClick={() => setConfirm("submit")}>
                <Send className="size-4" /> إرسال للاعتماد
              </Button>
            )}
            {count.status === "submitted" && isManager && (
              <Button variant="outline" onClick={() => setConfirm("reopen")}>
                <RotateCcw className="size-4" /> إعادة فتح
              </Button>
            )}
            {(count.status === "open" || count.status === "submitted") && isManager && (
              <>
                <Button variant="outline" onClick={() => setCancelOpen(true)}>
                  <XCircle className="size-4" /> إلغاء
                </Button>
                <Button onClick={() => setApproveOpen(true)}>
                  <CheckCircle2 className="size-4" /> مراجعة واعتماد
                </Button>
              </>
            )}
          </>
        }
      />

      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="الأصناف" value={num(items.length)} />
        <Stat label="تم عدّها" value={`${num(counted)} / ${num(items.length)}`} tone="blue" />
        {isManager && <Stat label="عجز (قطع)" value={num(variance.shortage)} tone="red" />}
        {isManager && <Stat label="زيادة (قطع)" value={num(variance.surplus)} tone="green" hint={`صافي القيمة ${money(variance.value)}`} />}
      </div>

      {isManager && count.snapshot_at && (
        <p className="mb-4 rounded-lg bg-sky-50 p-3 text-xs text-sky-800">
          اللقطة: {dateTime(count.snapshot_at)}. النظامي لكل صنف = رصيد اللقطة + حركات الموقع بعدها حتى لحظة عدّ الصنف (بيع، مرتجع، تحويل…)، فالبيع أثناء
          الجرد لا يصنع فروقات وهمية.
        </p>
      )}

      {editable && (
        <Card className="mb-4 p-4">
          <form
            onSubmit={(e) => {
              e.preventDefault();
              onScan();
            }}
            className="flex gap-2"
          >
            <div className="relative min-w-0 flex-1">
              <ScanBarcode className="pointer-events-none absolute start-3 top-1/2 size-5 -translate-y-1/2 text-slate-400" />
              <Input
                ref={scanRef}
                autoFocus
                aria-label="مسح الباركود"
                className="h-12 ps-10 text-base"
                placeholder="امسح الباركود أو اكتب SKU — كل مسح يضيف 1"
                value={scan}
                onChange={(e) => setScan(e.target.value)}
              />
            </div>
            <CameraScanButton onClick={() => setShowCamera(true)} />
          </form>
        </Card>
      )}

      <Card>
        <div className="flex flex-wrap gap-2 border-b border-slate-100 p-3">
          <Input className="min-w-52 flex-1" placeholder="بحث" value={q} onChange={(e) => setQ(e.target.value)} />
          <Select className="w-auto" value={view} onChange={(e) => setView(e.target.value as typeof view)}>
            <option value="all">الكل</option>
            <option value="uncounted">لم يُعد</option>
            {isManager && <option value="diff">فروقات</option>}
          </Select>
        </div>
        <Table>
          <thead>
            <tr>
              <th>الصنف</th>
              <th>SKU</th>
              {isManager && <th>اللقطة</th>}
              {isManager && <th>حركات بعدها</th>}
              {isManager && <th>النظامي</th>}
              <th>المعدود</th>
              {isManager && <th>الفرق</th>}
            </tr>
          </thead>
          <tbody>
            {filtered.slice(0, 1000).map((i) => {
              const r = review[i.variant_id];
              const diff = i.counted_qty === null || !r ? null : i.counted_qty - r.expected_qty;
              return (
                <tr key={i.id} className={cn(lastScanned === i.variant_id && "bg-emerald-50")}>
                  <td>
                    <p className="font-medium">{i.variant.product.name}</p>
                    <p className="text-xs text-slate-500">{variantLabel(i.variant.size, i.variant.color)}</p>
                  </td>
                  <td className="ltr-nums text-xs text-slate-500">{i.variant.sku}</td>
                  {isManager && <td>{r?.snapshot_qty ?? "-"}</td>}
                  {isManager && <td>{r ? (r.moves_after_snapshot > 0 ? `+${r.moves_after_snapshot}` : r.moves_after_snapshot || "-") : "-"}</td>}
                  {isManager && <td>{r?.expected_qty ?? "-"}</td>}
                  <td>
                    {editable ? (
                      <Input
                        key={`${i.id}-${i.counted_qty}`}
                        type="number"
                        min={0}
                        aria-label={`المعدود ${i.variant.sku}`}
                        className="h-9 w-24"
                        defaultValue={i.counted_qty ?? ""}
                        onBlur={(e) => {
                          const v = e.target.value;
                          if (v === "" || Number(v) === i.counted_qty) return;
                          setQty(i, Math.max(0, Math.floor(Number(v))));
                        }}
                      />
                    ) : (
                      (i.counted_qty ?? "-")
                    )}
                  </td>
                  {isManager && (
                    <td>
                      {diff === null ? (
                        "-"
                      ) : diff === 0 ? (
                        <Badge tone="green">مطابق</Badge>
                      ) : (
                        <Badge tone={diff < 0 ? "red" : "blue"}>{diff > 0 ? `+${diff}` : diff}</Badge>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </Table>
      </Card>

      <CameraScanner
        open={showCamera}
        continuous
        title="جرد بالكاميرا — كل مسح يضيف 1"
        onClose={() => {
          setShowCamera(false);
          scanRef.current?.focus();
        }}
        onDetected={(code) => {
          // الكاميرا تنتظر نتيجة فورية: نُظهر «تم» ثم نُبلغ بالخطأ إن رفضه الخادم
          void sendScan(code).then((o) => !o.ok && toast(o.message, "error"));
          return { ok: true, message: `تم مسح ${code}` };
        }}
      />

      <ConfirmDialog
        open={confirm === "submit"}
        title="إرسال الجرد للاعتماد"
        message="بعد الإرسال لا يمكن إضافة مسحات إلا إذا أعاد المدير فتح الجرد."
        confirmLabel="إرسال"
        loading={busy}
        onConfirm={async () => {
          await rpc("submit_count", { p_count_id: id }, "تم إرسال الجرد");
          setConfirm(null);
        }}
        onClose={() => setConfirm(null)}
      />
      <ConfirmDialog
        open={confirm === "reopen"}
        title="إعادة فتح الجرد"
        message="يمكن للفريق متابعة المسح بعد إعادة الفتح."
        confirmLabel="إعادة فتح"
        loading={busy}
        onConfirm={async () => {
          await rpc("reopen_count", { p_count_id: id }, "تمت إعادة فتح الجرد");
          setConfirm(null);
        }}
        onClose={() => setConfirm(null)}
      />
      {approveOpen && (
        <ApproveDialog
          legacy={legacy}
          uncounted={items.length - counted}
          variance={variance}
          diffs={items.filter((i) => i.counted_qty !== null && review[i.variant_id] && i.counted_qty !== review[i.variant_id].expected_qty).length}
          busy={busy}
          onClose={() => setApproveOpen(false)}
          onApprove={async (zero, note) => {
            if (legacy) {
              if (count.status === "submitted") await supabase().rpc("reopen_count", { p_count_id: id });
              const r = await rpc("apply_stock_count", { p_count_id: id }, "تم اعتماد الجرد");
              if (r !== null) setApproveOpen(false);
              return;
            }
            const r = await rpc("approve_count", { p_count_id: id, p_uncounted_as_zero: zero, p_note: note || null }, "تم اعتماد الجرد");
            if (r !== null) setApproveOpen(false);
          }}
        />
      )}
      {cancelOpen && (
        <CancelDialog
          busy={busy}
          onClose={() => setCancelOpen(false)}
          onCancel={async (reason) => {
            const r = await rpc("cancel_count", { p_count_id: id, p_reason: reason }, "تم إلغاء الجرد");
            if (r !== null) setCancelOpen(false);
          }}
        />
      )}
    </div>
  );
}

function ApproveDialog({
  legacy,
  uncounted,
  variance,
  diffs,
  busy,
  onClose,
  onApprove,
}: {
  legacy: boolean;
  uncounted: number;
  variance: { shortage: number; surplus: number; value: number };
  diffs: number;
  busy: boolean;
  onClose: () => void;
  onApprove: (uncountedAsZero: boolean, note: string) => void;
}) {
  const [zero, setZero] = useState(false);
  const [note, setNote] = useState("");
  return (
    <Modal
      open
      onClose={onClose}
      title="اعتماد الجرد وتسوية الفروقات"
      size="sm"
      footer={
        <Button onClick={() => onApprove(zero, note)} loading={busy}>
          اعتماد
        </Button>
      }
    >
      <div className="space-y-3 text-sm">
        <p>
          فروقات في {num(diffs)} صنف: عجز {num(variance.shortage)} قطعة، زيادة {num(variance.surplus)} قطعة، صافي القيمة{" "}
          <b className={variance.value < 0 ? "text-red-600" : "text-emerald-700"}>{money(variance.value)}</b>.
        </p>
        <p className="text-slate-600">التسوية = المعدود − النظامي وقت العدّ، فتبقى مبيعات أثناء الجرد صحيحة. لا يُسمح بأن يصبح رصيد الموقع سالباً.</p>
        {!legacy && uncounted > 0 && (
          <Checkbox label={`اعتبر الأصناف غير المعدودة (${num(uncounted)}) صفراً — للجرد الكامل فقط`} checked={zero} onChange={setZero} />
        )}
        {!legacy && (
          <Field label="ملاحظة">
            <Input value={note} onChange={(e) => setNote(e.target.value)} />
          </Field>
        )}
      </div>
    </Modal>
  );
}

function CancelDialog({ busy, onClose, onCancel }: { busy: boolean; onClose: () => void; onCancel: (reason: string) => void }) {
  const [reason, setReason] = useState("");
  return (
    <Modal
      open
      onClose={onClose}
      title="إلغاء الجرد"
      size="sm"
      footer={
        <Button variant="danger" onClick={() => onCancel(reason.trim())} loading={busy} disabled={!reason.trim()}>
          إلغاء الجرد
        </Button>
      }
    >
      <Field label="السبب (إلزامي) — لن تُعدل أي كميات">
        <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
    </Modal>
  );
}
