"use client";

import { ArrowLeft, Plus } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import { NewTransferModal } from "@/components/new-transfer-modal";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, EmptyState, Loading, PageHeader, Select, Table, useToast } from "@/components/ui";
import { dateTime, errorMessage, num } from "@/lib/format";
import { TRANSFER_STATUS, fetchLocations, fetchMyLocationId, type Location, type Transfer, type TransferStatus } from "@/lib/inventory";
import { supabase } from "@/lib/supabase/client";

type Row = Transfer & { items: Array<{ qty_requested: number; qty_shipped: number; qty_received: number; qty_lost: number }> };
const OPEN: TransferStatus[] = ["requested", "approved", "in_transit", "short_received"];

export function TransfersList() {
  const toast = useToast();
  const router = useRouter();
  const { profile } = useSession();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [locations, setLocations] = useState<Location[]>([]);
  const [myLocation, setMyLocation] = useState("");
  const [filter, setFilter] = useState<"open" | "all" | TransferStatus>("open");
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    try {
      const [locs, { data, error }] = await Promise.all([
        fetchLocations(),
        supabase()
          .from("transfers")
          .select("*, items:transfer_items(qty_requested, qty_shipped, qty_received, qty_lost)")
          .order("requested_at", { ascending: false })
          .limit(300),
      ]);
      if (error) throw error;
      setLocations(locs);
      setRows((data ?? []) as Row[]);
      setMyLocation(await fetchMyLocationId(profile.id, locs));
    } catch (e) {
      toast(errorMessage(e), "error");
      setRows((r) => r ?? []);
    }
  }, [profile.id, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const name = useMemo(() => Object.fromEntries(locations.map((l) => [l.id, l.name])), [locations]);
  const shown = (rows ?? []).filter((r) => (filter === "open" ? OPEN.includes(r.status) : filter === "all" || r.status === filter));
  const count = (s: TransferStatus) => (rows ?? []).filter((r) => r.status === s).length;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="التحويلات بين المواقع"
        subtitle="طلب ← اعتماد ← شحن ← استلام. الشحن والاستلام الجزئي مسموحان، والفرق لا يُخصم إلا باعتماد المدير"
        actions={
          <Button onClick={() => setCreating(true)} disabled={locations.length < 2}>
            <Plus className="size-4" /> طلب تحويل
          </Button>
        }
      />
      {locations.length > 0 && locations.length < 2 && (
        <p className="mb-4 rounded-lg bg-amber-50 p-3 text-sm text-amber-800">
          يوجد موقع واحد فقط. أضف فرعاً أو مستودعاً من «الفروع والمستودعات» لتفعيل التحويلات.
        </p>
      )}
      <div className="mb-3 flex flex-wrap gap-2">
        <Select aria-label="تصفية الحالة" className="w-auto" value={filter} onChange={(e) => setFilter(e.target.value as typeof filter)}>
          <option value="open">المفتوحة</option>
          <option value="all">الكل</option>
          {(Object.keys(TRANSFER_STATUS) as TransferStatus[]).map((s) => (
            <option key={s} value={s}>
              {TRANSFER_STATUS[s].label} ({count(s)})
            </option>
          ))}
        </Select>
      </div>
      <Card>
        {rows === null ? (
          <Loading />
        ) : shown.length === 0 ? (
          <EmptyState title="لا توجد تحويلات" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>الرقم</th>
                <th>من ← إلى</th>
                <th>القطع</th>
                <th>التاريخ</th>
                <th>الحالة</th>
              </tr>
            </thead>
            <tbody>
              {shown.map((t) => {
                const req = t.items.reduce((s, i) => s + i.qty_requested, 0);
                const shipped = t.items.reduce((s, i) => s + i.qty_shipped, 0);
                const recv = t.items.reduce((s, i) => s + i.qty_received, 0);
                return (
                  <tr key={t.id}>
                    <td>
                      <Link href={`/transfers/${t.id}`} className="ltr-nums font-medium text-brand-700 hover:underline">
                        {t.transfer_no}
                      </Link>
                    </td>
                    <td>
                      <span className="inline-flex items-center gap-1">
                        {name[t.from_location] ?? "-"} <ArrowLeft className="size-3.5 text-slate-400" /> {name[t.to_location] ?? "-"}
                      </span>
                    </td>
                    <td className="text-xs text-slate-600">
                      طُلب {num(req)} · شُحن {num(shipped)} · استُلم {num(recv)}
                    </td>
                    <td className="ltr-nums text-xs">{dateTime(t.requested_at)}</td>
                    <td>
                      <Badge tone={TRANSFER_STATUS[t.status].tone}>{TRANSFER_STATUS[t.status].label}</Badge>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>

      {creating && (
        <NewTransferModal
          locations={locations}
          defaultTo={profile.role === "cashier" ? myLocation : ""}
          onClose={() => setCreating(false)}
          onCreated={(id) => router.push(`/transfers/${id}`)}
        />
      )}
    </div>
  );
}
