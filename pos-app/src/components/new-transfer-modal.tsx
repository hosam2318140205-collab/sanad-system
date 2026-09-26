"use client";

import { Trash2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { errorMessage, variantLabel } from "@/lib/format";
import { newRef, type Location, type VariantLocation } from "@/lib/inventory";
import { supabase } from "@/lib/supabase/client";
import { Button, Field, Input, Modal, Select, Textarea, useToast } from "./ui";
import { VariantSearch } from "./variant-search";

export interface TransferLine {
  variant_id: string;
  name: string;
  label: string;
  sku: string;
  qty: number;
}

/** طلب تحويل: من أين، إلى أين، والأصناف. المفتاح (client_ref) ثابت لكل نافذة فلا يتكرر الطلب بالضغط المزدوج */
export function NewTransferModal({
  locations,
  defaultFrom = "",
  defaultTo = "",
  initialLines = [],
  onClose,
  onCreated,
}: {
  locations: Location[];
  defaultFrom?: string;
  defaultTo?: string;
  initialLines?: TransferLine[];
  onClose: () => void;
  onCreated: (id: string) => void;
}) {
  const toast = useToast();
  const [from, setFrom] = useState(defaultFrom);
  const [to, setTo] = useState(defaultTo);
  const [lines, setLines] = useState<TransferLine[]>(initialLines);
  const [notes, setNotes] = useState("");
  const [avail, setAvail] = useState<Record<string, VariantLocation[]>>({});
  const [busy, setBusy] = useState(false);
  const ref = useRef(newRef());

  useEffect(() => {
    const missing = lines.filter((l) => !avail[l.variant_id]);
    if (missing.length === 0) return;
    let alive = true;
    Promise.all(
      missing.map(async (l) => {
        const { data } = await supabase().rpc("variant_locations", { p_variant: l.variant_id });
        return [l.variant_id, (data ?? []) as VariantLocation[]] as const;
      }),
    ).then((pairs) => alive && setAvail((a) => ({ ...a, ...Object.fromEntries(pairs) })));
    return () => {
      alive = false;
    };
  }, [lines, avail]);

  const availAt = (variantId: string, locationId: string) =>
    avail[variantId]?.find((v) => v.location_id === locationId)?.available ?? (avail[variantId] ? 0 : null);

  const submit = async () => {
    if (!from || !to) return toast("اختر موقع المصدر والوجهة", "error");
    if (from === to) return toast("اختر موقعين مختلفين", "error");
    const items = lines.filter((l) => l.qty > 0).map((l) => ({ variant_id: l.variant_id, qty: l.qty }));
    if (items.length === 0) return toast("أضف صنفاً واحداً على الأقل", "error");
    setBusy(true);
    const { data, error } = await supabase().rpc("request_transfer", {
      p_from: from,
      p_to: to,
      p_items: items,
      p_notes: notes || null,
      p_client_ref: ref.current,
    });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم إنشاء طلب التحويل");
    onCreated(data as string);
  };

  return (
    <Modal
      open
      onClose={onClose}
      title="طلب تحويل"
      size="lg"
      footer={
        <Button onClick={submit} loading={busy}>
          إرسال الطلب
        </Button>
      }
    >
      <div className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="من">
            <Select aria-label="من موقع" value={from} onChange={(e) => setFrom(e.target.value)}>
              <option value="">اختر</option>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="إلى">
            <Select aria-label="إلى موقع" value={to} onChange={(e) => setTo(e.target.value)}>
              <option value="">اختر</option>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </Select>
          </Field>
        </div>
        <VariantSearch
          placeholder="أضف صنفاً بالاسم أو الباركود"
          onPick={(item) =>
            setLines((ls) =>
              ls.some((l) => l.variant_id === item.variant_id)
                ? ls.map((l) => (l.variant_id === item.variant_id ? { ...l, qty: l.qty + 1 } : l))
                : [
                    ...ls,
                    {
                      variant_id: item.variant_id,
                      name: item.product_name,
                      label: variantLabel(item.size, item.color),
                      sku: item.sku,
                      qty: 1,
                    },
                  ],
            )
          }
        />
        {lines.length > 0 && (
          <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200">
            {lines.map((l) => {
              const a = from ? availAt(l.variant_id, from) : null;
              const where = (avail[l.variant_id] ?? []).filter((v) => v.location_id !== from && v.available > 0);
              return (
                <li key={l.variant_id} className="flex flex-wrap items-center gap-3 p-3">
                  <div className="min-w-0 flex-1">
                    <p className="font-medium">
                      {l.name} {l.label && <span className="text-sm text-slate-500">({l.label})</span>}
                    </p>
                    <p className="text-xs text-slate-500">
                      {a !== null && <>المتاح في المصدر: <b className={a < l.qty ? "text-red-600" : "text-emerald-700"}>{a}</b></>}
                      {where.length > 0 && <> · متوفر أيضاً: {where.map((w) => `${w.location_name} ${w.available}`).join("، ")}</>}
                    </p>
                  </div>
                  <Input
                    type="number"
                    min={1}
                    aria-label={`كمية ${l.name}`}
                    className="h-9 w-24"
                    value={l.qty || ""}
                    onChange={(e) => setLines((ls) => ls.map((x) => (x.variant_id === l.variant_id ? { ...x, qty: Math.max(0, Number(e.target.value) || 0) } : x)))}
                  />
                  <Button size="sm" variant="ghost" aria-label="حذف" onClick={() => setLines((ls) => ls.filter((x) => x.variant_id !== l.variant_id))}>
                    <Trash2 className="size-4" />
                  </Button>
                </li>
              );
            })}
          </ul>
        )}
        <Field label="ملاحظات">
          <Textarea rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
        <p className="text-xs text-slate-500">
          التحويل لا يُعد بيعاً ولا شراءً ولا يؤثر على الأرباح أو الضريبة. يُحجز من المتاح عند الاعتماد، ويُنقل فعلياً عند الشحن ثم الاستلام.
        </p>
      </div>
    </Modal>
  );
}
