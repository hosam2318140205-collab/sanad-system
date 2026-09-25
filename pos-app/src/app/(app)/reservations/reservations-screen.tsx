"use client";

import { BookmarkPlus, Search, Trash2 } from "lucide-react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Textarea, cn, useToast } from "@/components/ui";
import { VariantSearch } from "@/components/variant-search";
import { COLLECTION_METHOD_LABELS, isReservationExpired, newClientRef, reservationState } from "@/lib/customers";
import { dateTime, errorMessage, money, variantLabel } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { CatalogItem, CollectionMethod, Customer, Reservation } from "@/lib/types";

type Row = Reservation & {
  customer: { id: string; name: string; phone: string | null } | null;
  items: Array<{ qty: number; variant: { sku: string; size: string | null; color: string | null; product: { name: string } } }>;
};
type Filter = "active" | "expired" | "fulfilled" | "cancelled" | "all";
const FILTERS: Array<[Filter, string]> = [
  ["active", "نشطة"],
  ["expired", "منتهية"],
  ["fulfilled", "مستلمة"],
  ["cancelled", "ملغاة"],
  ["all", "الكل"],
];

export function ReservationsScreen() {
  const toast = useToast();
  const router = useRouter();
  const params = useSearchParams();
  const { settings, isManager, profile } = useSession();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [filter, setFilter] = useState<Filter>("active");
  const [q, setQ] = useState("");
  const [creating, setCreating] = useState(!!params.get("customer"));

  const load = useCallback(async () => {
    const { data, error } = await supabase()
      .from("reservations")
      .select("*, customer:customers(id, name, phone), items:reservation_items(qty, variant:product_variants(sku, size, color, product:products(name)))")
      .order("created_at", { ascending: false })
      .limit(300);
    if (error) toast(errorMessage(error), "error");
    setRows((data ?? []) as unknown as Row[]);
  }, [toast]);

  useEffect(() => {
    (async () => {
      await load();
    })();
  }, [load]);

  const list = useMemo(() => {
    const term = q.trim().toLowerCase();
    return (rows ?? []).filter((r) => {
      const expired = isReservationExpired(r);
      const st = r.status === "active" ? (expired ? "expired" : "active") : r.status;
      if (filter !== "all" && st !== filter) return false;
      if (!term) return true;
      return [r.reservation_no, r.customer?.name, r.customer?.phone].some((v) => v?.toLowerCase().includes(term));
    });
  }, [rows, filter, q]);

  const cancel = async (r: Row) => {
    const reason = window.prompt(`سبب إلغاء الحجز ${r.reservation_no}`);
    if (!reason?.trim()) return;
    const { error } = await supabase().rpc("cancel_reservation", { p_reservation_id: r.id, p_reason: reason.trim() });
    if (error) return toast(errorMessage(error), "error");
    toast("تم إلغاء الحجز");
    load();
  };
  const extend = async (r: Row) => {
    const { error } = await supabase().rpc("extend_reservation", { p_reservation_id: r.id, p_days: settings.reservation_days });
    if (error) return toast(errorMessage(error), "error");
    toast(`تم التمديد ${settings.reservation_days} أيام`);
    load();
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="الحجوزات"
        subtitle="حجز مقاس/لون محدد لعميل حتى تاريخ معين — الكمية المحجوزة لا تُباع لغيره"
        actions={
          <Button onClick={() => setCreating(true)}>
            <BookmarkPlus className="size-4" /> حجز جديد
          </Button>
        }
      />
      <Card className="mb-3 p-3">
        <div className="flex flex-col gap-2 md:flex-row">
          <div className="relative flex-1">
            <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <Input className="ps-9" placeholder="رقم الحجز، اسم العميل أو الجوال" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
          <div className="flex gap-1 overflow-x-auto rounded-lg bg-slate-100 p-1 scrollbar-thin">
            {FILTERS.map(([k, label]) => (
              <button
                key={k}
                onClick={() => setFilter(k)}
                className={cn("shrink-0 rounded-md px-3 py-1.5 text-sm", filter === k ? "bg-white font-medium shadow-sm" : "text-slate-600")}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
      </Card>

      {rows === null ? (
        <Loading />
      ) : list.length === 0 ? (
        <Card>
          <EmptyState title="لا توجد حجوزات" />
        </Card>
      ) : (
        <div className="grid gap-3 lg:grid-cols-2">
          {list.map((r) => {
            const st = reservationState(r);
            const canCancel = isManager || r.created_by === profile.id;
            return (
              <Card key={r.id} className="p-4" >
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-semibold" dir="ltr">
                    {r.reservation_no}
                  </span>
                  <Badge tone={st.tone}>{st.label}</Badge>
                  {r.customer && (
                    <Link href={`/customers/${r.customer.id}`} className="text-sm text-brand-700 hover:underline">
                      {r.customer.name}
                    </Link>
                  )}
                  <span className="ms-auto text-xs text-slate-500">حتى {dateTime(r.expires_at)}</span>
                </div>
                <ul className="mt-2 space-y-0.5 text-sm">
                  {r.items.map((i, idx) => (
                    <li key={idx}>
                      {i.variant.product.name}
                      <span className="text-slate-500"> {variantLabel(i.variant.size, i.variant.color) && `(${variantLabel(i.variant.size, i.variant.color)})`}</span> × {i.qty}
                    </li>
                  ))}
                </ul>
                {r.notes && <p className="mt-1 text-xs text-slate-500">{r.notes}</p>}
                {r.status === "active" && (
                  <div className="mt-3 flex flex-wrap gap-2">
                    <Button size="sm" onClick={() => router.push(`/pos?reservation=${r.id}`)}>
                      استلام في نقطة البيع
                    </Button>
                    <Button size="sm" variant="outline" onClick={() => extend(r)}>
                      تمديد {settings.reservation_days} أيام
                    </Button>
                    {canCancel && (
                      <Button size="sm" variant="ghost" className="text-red-600" onClick={() => cancel(r)}>
                        إلغاء
                      </Button>
                    )}
                  </div>
                )}
                {r.status === "cancelled" && r.cancel_reason && <p className="mt-2 text-xs text-slate-500">سبب الإلغاء: {r.cancel_reason}</p>}
              </Card>
            );
          })}
        </div>
      )}

      {creating && (
        <NewReservation
          initialCustomerId={params.get("customer")}
          onClose={() => setCreating(false)}
          onCreated={() => {
            setCreating(false);
            load();
          }}
        />
      )}
    </div>
  );
}

function NewReservation({
  initialCustomerId,
  onClose,
  onCreated,
}: {
  initialCustomerId: string | null;
  onClose: () => void;
  onCreated: () => void;
}) {
  const toast = useToast();
  const { settings } = useSession();
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [cq, setCq] = useState("");
  const [results, setResults] = useState<Customer[]>([]);
  const [items, setItems] = useState<Array<{ item: CatalogItem; qty: number }>>([]);
  const [days, setDays] = useState(String(settings.reservation_days));
  const [notes, setNotes] = useState("");
  const [deposit, setDeposit] = useState("");
  const [depositMethod, setDepositMethod] = useState<CollectionMethod>("cash_drawer");
  const [busy, setBusy] = useState(false);
  const [refs] = useState(() => ({ reservation: newClientRef(), deposit: newClientRef() }));

  useEffect(() => {
    if (!initialCustomerId) return;
    supabase()
      .from("customers")
      .select("*")
      .eq("id", initialCustomerId)
      .maybeSingle()
      .then(({ data }) => data && setCustomer(data as Customer));
  }, [initialCustomerId]);

  useEffect(() => {
    if (customer) return;
    const term = cq.trim().replace(/[%,()]/g, "");
    const t = setTimeout(async () => {
      if (!term) return setResults([]);
      const { data } = await supabase().from("customers").select("*").or(`name.ilike.%${term}%,phone.ilike.%${term}%`).limit(8);
      setResults((data ?? []) as Customer[]);
    }, 200);
    return () => clearTimeout(t);
  }, [cq, customer]);

  const add = (item: CatalogItem) =>
    setItems((list) =>
      list.some((l) => l.item.variant_id === item.variant_id)
        ? list.map((l) => (l.item.variant_id === item.variant_id ? { ...l, qty: l.qty + 1 } : l))
        : [...list, { item, qty: 1 }],
    );

  const submit = async () => {
    if (!customer) return toast("اختر العميل", "error");
    if (items.length === 0) return toast("أضف الأصناف المحجوزة", "error");
    setBusy(true);
    const db = supabase();
    const { data, error } = await db.rpc("create_reservation", {
      p_customer_id: customer.id,
      p_items: items.map((l) => ({ variant_id: l.item.variant_id, qty: l.qty })),
      p_days: Number(days) || null,
      p_notes: notes || null,
      p_client_ref: refs.reservation,
    });
    if (error) {
      setBusy(false);
      return toast(errorMessage(error), "error");
    }
    const amount = Number(deposit);
    if (amount > 0) {
      const dep = await db.rpc("record_customer_payment", {
        p_customer_id: customer.id,
        p_amount: amount,
        p_method: depositMethod,
        p_kind: "receipt",
        p_notes: "عربون حجز",
        p_client_ref: refs.deposit,
        p_reservation_id: data as string,
      });
      if (dep.error) {
        setBusy(false);
        toast(`تم الحجز، لكن تعذر تسجيل العربون: ${errorMessage(dep.error)}`, "error");
        onCreated();
        return;
      }
    }
    setBusy(false);
    toast("تم إنشاء الحجز" + (amount > 0 ? ` وتسجيل عربون ${money(amount)}` : ""));
    onCreated();
  };

  return (
    <Modal
      open
      onClose={onClose}
      title="حجز جديد"
      size="lg"
      footer={
        <Button onClick={submit} loading={busy}>
          حفظ الحجز
        </Button>
      }
    >
      <div className="space-y-4">
        {customer ? (
          <div className="flex items-center justify-between rounded-lg bg-slate-50 p-3">
            <span className="font-medium">
              {customer.name} <span className="ltr-nums text-sm text-slate-500">{customer.phone}</span>
            </span>
            <button className="text-sm text-brand-700 hover:underline" onClick={() => setCustomer(null)}>
              تغيير
            </button>
          </div>
        ) : (
          <div>
            <Input placeholder="ابحث عن العميل بالاسم أو الجوال" value={cq} onChange={(e) => setCq(e.target.value)} aria-label="العميل" autoFocus />
            {results.length > 0 && (
              <ul className="mt-1 divide-y divide-slate-100 rounded-lg border border-slate-200">
                {results.map((c) => (
                  <li key={c.id}>
                    <button className="flex w-full justify-between px-3 py-2 text-start hover:bg-slate-50" onClick={() => setCustomer(c)}>
                      <span>{c.name}</span>
                      <span className="ltr-nums text-sm text-slate-500">{c.phone}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        <div>
          <p className="mb-1 text-sm font-medium text-slate-700">الأصناف (المقاس واللون)</p>
          <VariantSearch onPick={add} placeholder="ابحث أو امسح باركود المقاس/اللون" />
          {items.length > 0 && (
            <ul className="mt-2 divide-y divide-slate-100 rounded-lg border border-slate-200">
              {items.map((l) => (
                <li key={l.item.variant_id} className="flex items-center gap-2 p-2 text-sm">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-medium">{l.item.product_name}</p>
                    <p className="text-xs text-slate-500">
                      {variantLabel(l.item.size, l.item.color) || l.item.sku} · المخزون {l.item.stock_qty}
                    </p>
                  </div>
                  <Input
                    type="number"
                    min={1}
                    className="h-9 w-20"
                    value={l.qty}
                    aria-label={`كمية ${l.item.sku}`}
                    onChange={(e) =>
                      setItems((list) => list.map((x) => (x.item.variant_id === l.item.variant_id ? { ...x, qty: Math.max(1, Number(e.target.value) || 1) } : x)))
                    }
                  />
                  <button className="p-1.5 text-slate-400 hover:text-red-600" onClick={() => setItems((list) => list.filter((x) => x !== l))} aria-label="حذف">
                    <Trash2 className="size-4" />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="مدة الحجز (أيام)">
            <Input type="number" min={1} max={60} value={days} onChange={(e) => setDays(e.target.value)} />
          </Field>
          <Field label="عربون (اختياري)">
            <Input type="number" min={0} step="0.01" value={deposit} onChange={(e) => setDeposit(e.target.value)} placeholder="0" aria-label="عربون" />
          </Field>
          <Field label="طريقة العربون">
            <Select value={depositMethod} onChange={(e) => setDepositMethod(e.target.value as CollectionMethod)}>
              {(["cash_drawer", "card", "transfer"] as const).map((m) => (
                <option key={m} value={m}>
                  {COLLECTION_METHOD_LABELS[m]}
                </option>
              ))}
            </Select>
          </Field>
        </div>
        <Field label="ملاحظات">
          <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="مثال: يحتاج تقصير، يتصل قبل الاستلام" />
        </Field>
        <p className="text-xs text-slate-500">العربون يُضاف لرصيد العميل الدائن ويُخصم تلقائياً عند الاستلام بطريقة «آجل».</p>
      </div>
    </Modal>
  );
}
