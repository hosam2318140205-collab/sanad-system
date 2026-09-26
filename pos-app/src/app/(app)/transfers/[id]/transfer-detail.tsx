"use client";

import { ArrowLeft, ArrowRight, Ban, CheckCircle2, PackageCheck, Truck, TriangleAlert } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, Checkbox, Field, Input, Loading, Modal, PageHeader, Table, Textarea, useToast } from "@/components/ui";
import { dateTime, errorMessage, num, variantLabel } from "@/lib/format";
import {
  TRANSFER_EVENTS,
  TRANSFER_STATUS,
  fetchLocations,
  fetchMyLocationId,
  newRef,
  type Location,
  type Transfer,
  type TransferEvent,
  type TransferItem,
} from "@/lib/inventory";
import { supabase } from "@/lib/supabase/client";

type Action = "approve" | "ship" | "receive" | "reject" | "cancel";

export function TransferDetail({ id }: { id: string }) {
  const toast = useToast();
  const { profile, isManager, settings } = useSession();
  const [t, setT] = useState<Transfer | null>(null);
  const [items, setItems] = useState<TransferItem[]>([]);
  const [events, setEvents] = useState<TransferEvent[]>([]);
  const [locations, setLocations] = useState<Location[]>([]);
  const [names, setNames] = useState<Record<string, string>>({});
  const [myLocation, setMyLocation] = useState("");
  const [missing, setMissing] = useState(false);
  const [action, setAction] = useState<Action | null>(null);
  const [loss, setLoss] = useState<TransferItem | null>(null);

  const load = useCallback(async () => {
    const db = supabase();
    try {
      const [{ data: tr }, { data: its }, { data: evs }, locs] = await Promise.all([
        db.from("transfers").select("*").eq("id", id).maybeSingle(),
        db
          .from("transfer_items")
          .select("*, variant:product_variants(sku, barcode, size, color, product:products(name))")
          .eq("transfer_id", id)
          .order("id"),
        db.from("transfer_events").select("*").eq("transfer_id", id).order("id"),
        fetchLocations(true),
      ]);
      if (!tr) {
        setMissing(true);
        return;
      }
      setT(tr as Transfer);
      setItems(((its ?? []) as TransferItem[]).sort((a, b) => a.variant.product.name.localeCompare(b.variant.product.name, "ar")));
      setEvents((evs ?? []) as TransferEvent[]);
      setLocations(locs);
      setMyLocation(await fetchMyLocationId(profile.id, locs));
      const ids = [...new Set((evs ?? []).map((e) => e.created_by as string | null).filter(Boolean))] as string[];
      if (ids.length) {
        const { data: ps } = await db.from("profiles").select("id, full_name").in("id", ids);
        setNames(Object.fromEntries((ps ?? []).map((p) => [p.id as string, p.full_name as string])));
      }
    } catch (e) {
      toast(errorMessage(e), "error");
    }
  }, [id, profile.id, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const locName = useMemo(() => Object.fromEntries(locations.map((l) => [l.id, l.name])), [locations]);
  const variantName = useMemo(
    () => Object.fromEntries(items.map((i) => [i.variant_id, `${i.variant.product.name} ${variantLabel(i.variant.size, i.variant.color)}`.trim()])),
    [items],
  );

  if (missing) return <p className="p-6 text-slate-600">التحويل غير موجود أو ليس لديك صلاحية عرضه.</p>;
  if (!t) return <Loading />;

  const canAt = (loc: string) => isManager || myLocation === loc;
  const toShip = items.reduce((s, i) => s + i.qty_approved - i.qty_shipped, 0);
  const toReceive = items.reduce((s, i) => s + i.qty_shipped - i.qty_received - i.qty_lost, 0);
  const anyShipped = items.some((i) => i.qty_shipped > 0);
  const st = TRANSFER_STATUS[t.status];
  const active = ["approved", "in_transit", "short_received"].includes(t.status);
  const who = (uid: string | null) => (uid ? (uid === profile.id ? "أنت" : (names[uid] ?? "موظف")) : "-");

  const buttons = (
    <>
      <Link href="/transfers">
        <Button variant="ghost">
          <ArrowRight className="size-4" /> رجوع
        </Button>
      </Link>
      {t.status === "requested" && isManager && (
        <>
          <Button variant="outline" onClick={() => setAction("reject")}>
            <Ban className="size-4" /> رفض
          </Button>
          <Button onClick={() => setAction("approve")}>
            <CheckCircle2 className="size-4" /> اعتماد
          </Button>
        </>
      )}
      {((t.status === "requested" && (t.requested_by === profile.id || isManager)) || (t.status === "approved" && isManager && !anyShipped)) && (
        <Button variant="outline" onClick={() => setAction("cancel")}>
          إلغاء الطلب
        </Button>
      )}
      {active && toShip > 0 && canAt(t.from_location) && (
        <Button onClick={() => setAction("ship")}>
          <Truck className="size-4" /> شحن
        </Button>
      )}
      {active && toReceive > 0 && canAt(t.to_location) && (
        <Button onClick={() => setAction("receive")}>
          <PackageCheck className="size-4" /> استلام
        </Button>
      )}
    </>
  );

  return (
    <div className="p-4 md:p-6">
      <PageHeader title={`تحويل ${t.transfer_no}`} subtitle={t.notes ?? undefined} actions={buttons} />

      <Card className="mb-4 p-4">
        <div className="flex flex-wrap items-center gap-3">
          <Badge tone={st.tone}>{st.label}</Badge>
          <span className="inline-flex items-center gap-1.5 font-medium text-slate-800">
            {locName[t.from_location]} <ArrowLeft className="size-4 text-slate-400" /> {locName[t.to_location]}
          </span>
          {t.close_reason && <span className="text-sm text-slate-500">السبب: {t.close_reason}</span>}
        </div>
        {t.status === "short_received" && (
          <p className="mt-3 flex items-start gap-2 rounded-lg bg-red-50 p-3 text-sm text-red-800">
            <TriangleAlert className="mt-0.5 size-4 shrink-0" />
            وصل أقل مما شُحن. الفرق ({num(toReceive)} قطعة) ما زال «بالطريق» ولم يُخصم. يمكن تسجيل وصوله لاحقاً، أو يعتمد المدير فقده بسبب واضح.
            {settings.inventory_segregation && " (فصل المهام مفعّل: من سجّل الفرق لا يعتمد فقده)"}
          </p>
        )}
      </Card>

      <Card className="mb-4">
        <Table>
          <thead>
            <tr>
              <th>الصنف</th>
              <th>مطلوب</th>
              <th>معتمد</th>
              <th>مشحون</th>
              <th>مستلم</th>
              <th>فقد معتمد</th>
              <th>بالطريق</th>
              {t.status === "short_received" && isManager && <th></th>}
            </tr>
          </thead>
          <tbody>
            {items.map((i) => {
              const pending = i.qty_shipped - i.qty_received - i.qty_lost;
              return (
                <tr key={i.id}>
                  <td>
                    <p className="font-medium">{i.variant.product.name}</p>
                    <p className="text-xs text-slate-500">
                      {variantLabel(i.variant.size, i.variant.color)} · <span className="ltr-nums">{i.variant.sku}</span>
                    </p>
                  </td>
                  <td>{i.qty_requested}</td>
                  <td>{i.qty_approved}</td>
                  <td>{i.qty_shipped}</td>
                  <td>{i.qty_received}</td>
                  <td>{i.qty_lost || "-"}</td>
                  <td>{pending > 0 ? <Badge tone={t.status === "short_received" ? "red" : "violet"}>{pending}</Badge> : "-"}</td>
                  {t.status === "short_received" && isManager && (
                    <td>
                      {pending > 0 && (
                        <Button size="sm" variant="outline" onClick={() => setLoss(i)}>
                          اعتماد فقد
                        </Button>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </Table>
      </Card>

      <Card className="p-4">
        <h2 className="mb-3 font-semibold text-slate-900">التسلسل الزمني</h2>
        <ol className="space-y-3 border-s-2 border-slate-100 ps-4">
          {events.map((e) => (
            <li key={e.id} className="relative">
              <span className="absolute -start-[1.4rem] top-1.5 size-2.5 rounded-full bg-brand-700" />
              <p className="text-sm">
                <b>{TRANSFER_EVENTS[e.event] ?? e.event}</b>
                {e.variant_id && (
                  <>
                    {" "}
                    — {variantName[e.variant_id] ?? ""} × {e.qty}
                  </>
                )}
                {e.note && <span className="text-slate-500"> · {e.note}</span>}
              </p>
              <p className="ltr-nums text-xs text-slate-500">
                {dateTime(e.created_at)} · {who(e.created_by)}
              </p>
            </li>
          ))}
        </ol>
      </Card>

      {(action === "approve" || action === "ship" || action === "receive") && (
        <QtyDialog action={action} transfer={t} items={items} onClose={() => setAction(null)} onDone={() => (setAction(null), load())} />
      )}
      {(action === "reject" || action === "cancel") && (
        <ReasonDialog
          title={action === "reject" ? "رفض التحويل" : "إلغاء التحويل"}
          onClose={() => setAction(null)}
          onSubmit={async (reason) => {
            const { error } = await supabase().rpc("close_transfer", { p_id: t.id, p_reason: reason, p_reject: action === "reject" });
            if (error) return toast(errorMessage(error), "error");
            setAction(null);
            load();
          }}
        />
      )}
      {loss && <LossDialog transfer={t} item={loss} onClose={() => setLoss(null)} onDone={() => (setLoss(null), load())} />}
    </div>
  );
}

function QtyDialog({
  action,
  transfer,
  items,
  onClose,
  onDone,
}: {
  action: "approve" | "ship" | "receive";
  transfer: Transfer;
  items: TransferItem[];
  onClose: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const remaining = (i: TransferItem) =>
    action === "approve" ? i.qty_requested : action === "ship" ? i.qty_approved - i.qty_shipped : i.qty_shipped - i.qty_received - i.qty_lost;
  const lines = items.filter((i) => remaining(i) > 0);
  const [qty, setQty] = useState<Record<string, string>>(Object.fromEntries(lines.map((i) => [i.variant_id, String(remaining(i))])));
  const [flag, setFlag] = useState(action === "receive");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());

  const payload = lines.map((i) => ({ variant_id: i.variant_id, qty: Math.max(0, Math.min(remaining(i), Number(qty[i.variant_id]) || 0)) }));
  const total = payload.reduce((s, l) => s + l.qty, 0);
  const expected = lines.reduce((s, i) => s + remaining(i), 0);

  const submit = async () => {
    setBusy(true);
    const db = supabase();
    const { error } =
      action === "approve"
        ? await db.rpc("approve_transfer", { p_id: transfer.id, p_items: payload })
        : action === "ship"
          ? await db.rpc("ship_transfer", { p_id: transfer.id, p_items: payload, p_close_remaining: flag, p_client_ref: ref.current })
          : await db.rpc("receive_transfer", { p_id: transfer.id, p_items: payload, p_finalize: flag, p_client_ref: ref.current });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast(action === "approve" ? "تم الاعتماد" : action === "ship" ? "تم تسجيل الشحن" : "تم تسجيل الاستلام");
    onDone();
  };

  const titles = { approve: "اعتماد الكميات", ship: "شحن — الكمية الخارجة فعلياً", receive: "استلام — الكمية الواصلة فعلياً" };
  return (
    <Modal
      open
      onClose={onClose}
      title={titles[action]}
      size="md"
      footer={
        <Button onClick={submit} loading={busy} disabled={total === 0 && !(action === "ship" && flag)}>
          تأكيد ({num(total)} قطعة)
        </Button>
      }
    >
      <div className="space-y-3">
        {lines.map((i) => (
          <div key={i.id} className="flex items-center gap-3">
            <div className="min-w-0 flex-1">
              <p className="font-medium">{i.variant.product.name}</p>
              <p className="text-xs text-slate-500">
                {variantLabel(i.variant.size, i.variant.color)} · المتبقي {remaining(i)}
              </p>
            </div>
            <Input
              type="number"
              min={0}
              max={remaining(i)}
              aria-label={`كمية ${i.variant.product.name}`}
              className="h-9 w-24"
              value={qty[i.variant_id] ?? ""}
              onChange={(e) => setQty((q) => ({ ...q, [i.variant_id]: e.target.value }))}
            />
          </div>
        ))}
        {action === "approve" && (
          <p className="text-xs text-slate-500">يمكن اعتماد أقل من المطلوب. الكمية المعتمدة تُحجز من المتاح في المصدر فلا تُباع مرتين.</p>
        )}
        {action === "ship" && (
          <Checkbox label="لن يُشحن الباقي — أنهِ الشحن وألغِ غير المشحون" checked={flag} onChange={setFlag} />
        )}
        {action === "receive" && (
          <>
            <Checkbox label="إنهاء الاستلام: أي نقص يُسجل كفرق معلق بانتظار اعتماد المدير" checked={flag} onChange={setFlag} />
            {flag && total < expected && (
              <p className="rounded-lg bg-amber-50 p-2 text-xs text-amber-800">
                سيبقى {num(expected - total)} قطعة كفرق «بالطريق» — لا تُخصم كخسارة إلا باعتماد مدير وبسبب إلزامي.
              </p>
            )}
          </>
        )}
      </div>
    </Modal>
  );
}

function ReasonDialog({ title, onClose, onSubmit }: { title: string; onClose: () => void; onSubmit: (reason: string) => Promise<void> }) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <Modal
      open
      onClose={onClose}
      title={title}
      size="sm"
      footer={
        <Button
          variant="danger"
          loading={busy}
          disabled={!reason.trim()}
          onClick={async () => {
            setBusy(true);
            await onSubmit(reason.trim());
            setBusy(false);
          }}
        >
          تأكيد
        </Button>
      }
    >
      <Field label="السبب (إلزامي)">
        <Textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
    </Modal>
  );
}

function LossDialog({ transfer, item, onClose, onDone }: { transfer: Transfer; item: TransferItem; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const pending = item.qty_shipped - item.qty_received - item.qty_lost;
  const [qty, setQty] = useState(String(pending));
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());
  const submit = async () => {
    setBusy(true);
    const { error } = await supabase().rpc("resolve_transfer_loss", {
      p_id: transfer.id,
      p_variant: item.variant_id,
      p_qty: Number(qty) || 0,
      p_reason: reason.trim(),
      p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم اعتماد الفقد");
    onDone();
  };
  return (
    <Modal
      open
      onClose={onClose}
      title="اعتماد فقد أثناء النقل"
      size="sm"
      footer={
        <Button variant="danger" onClick={submit} loading={busy} disabled={!reason.trim() || !(Number(qty) > 0)}>
          اعتماد الفقد
        </Button>
      }
    >
      <div className="space-y-3">
        <p className="text-sm text-slate-600">
          {item.variant.product.name} {variantLabel(item.variant.size, item.variant.color)} — الفرق المعلق {pending}. سيُخصم من المخزون الإجمالي كتسوية فقد.
        </p>
        <Field label="الكمية المفقودة">
          <Input type="number" min={1} max={pending} value={qty} onChange={(e) => setQty(e.target.value)} />
        </Field>
        <Field label="السبب (إلزامي)">
          <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="تلف أثناء النقل / فقد مؤكد بعد المراجعة" />
        </Field>
      </div>
    </Modal>
  );
}
