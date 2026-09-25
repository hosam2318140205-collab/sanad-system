"use client";

import { MapPin, Pencil, Plus, Store, Warehouse } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Badge, Button, Card, Checkbox, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Table, useToast } from "@/components/ui";
import { ROLE_LABELS, errorMessage, num } from "@/lib/format";
import { LOCATION_KIND_LABELS, fetchLocations, type Location, type LocationKind } from "@/lib/inventory";
import { supabase } from "@/lib/supabase/client";
import type { Profile } from "@/lib/types";

type Draft = { id?: string; code: string; name: string; kind: LocationKind; is_active: boolean; address: string; phone: string };
const EMPTY: Draft = { code: "", name: "", kind: "store", is_active: true, address: "", phone: "" };

export function LocationsScreen() {
  const toast = useToast();
  const [locations, setLocations] = useState<Location[] | null>(null);
  const [staff, setStaff] = useState<Profile[]>([]);
  const [assigned, setAssigned] = useState<Record<string, string>>({});
  const [stock, setStock] = useState<Record<string, number>>({});
  const [edit, setEdit] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const db = supabase();
    try {
      const [locs, { data: profiles }, { data: links }, { data: qty }] = await Promise.all([
        fetchLocations(true),
        db.from("profiles").select("*").eq("is_active", true).order("full_name"),
        db.from("staff_locations").select("profile_id, location_id"),
        db.from("location_stock").select("location_id, qty").gt("qty", 0).limit(100000),
      ]);
      setLocations(locs);
      setStaff((profiles ?? []) as Profile[]);
      setAssigned(Object.fromEntries((links ?? []).map((l) => [l.profile_id as string, l.location_id as string])));
      const totals: Record<string, number> = {};
      for (const r of qty ?? []) totals[r.location_id as string] = (totals[r.location_id as string] ?? 0) + Number(r.qty);
      setStock(totals);
    } catch (e) {
      toast(errorMessage(e), "error");
      setLocations((l) => l ?? []);
    }
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const defaultId = useMemo(() => locations?.find((l) => l.is_default)?.id ?? "", [locations]);

  const save = async () => {
    if (!edit) return;
    if (!edit.code.trim() || !edit.name.trim()) return toast("الرمز والاسم مطلوبان", "error");
    setBusy(true);
    const row = {
      code: edit.code.trim().toUpperCase(),
      name: edit.name.trim(),
      kind: edit.kind,
      is_active: edit.is_active,
      address: edit.address.trim() || null,
      phone: edit.phone.trim() || null,
    };
    const db = supabase().from("locations");
    const { error } = edit.id ? await db.update(row).eq("id", edit.id) : await db.insert(row);
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم الحفظ");
    setEdit(null);
    load();
  };

  const assign = async (profileId: string, locationId: string) => {
    const prev = assigned[profileId];
    setAssigned((a) => ({ ...a, [profileId]: locationId }));
    const { error } = await supabase().rpc("set_staff_location", { p_profile: profileId, p_location: locationId || null });
    if (error) {
      setAssigned((a) => ({ ...a, [profileId]: prev }));
      toast(errorMessage(error), "error");
    }
  };

  if (!locations) return <Loading />;
  const active = locations.filter((l) => l.is_active);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="الفروع والمستودعات"
        subtitle="كل موقع له رصيده الخاص. البيع يخصم من فرع الوردية، والتحويل بين المواقع لا يُعد بيعاً ولا شراءً"
        actions={
          <Button onClick={() => setEdit({ ...EMPTY })}>
            <Plus className="size-4" /> موقع جديد
          </Button>
        }
      />

      <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {locations.map((l) => (
          <Card key={l.id} className="p-4">
            <div className="flex items-start justify-between gap-2">
              <div className="flex min-w-0 items-start gap-3">
                <div className="rounded-lg bg-slate-100 p-2 text-slate-600">
                  {l.kind === "warehouse" ? <Warehouse className="size-5" /> : <Store className="size-5" />}
                </div>
                <div className="min-w-0">
                  <p className="font-semibold text-slate-900">{l.name}</p>
                  <p className="ltr-nums text-xs text-slate-500">{l.code}</p>
                </div>
              </div>
              <Button
                size="sm"
                variant="ghost"
                aria-label={`تعديل ${l.name}`}
                onClick={() =>
                  setEdit({ id: l.id, code: l.code, name: l.name, kind: l.kind, is_active: l.is_active, address: l.address ?? "", phone: l.phone ?? "" })
                }
              >
                <Pencil className="size-4" />
              </Button>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-1.5">
              <Badge tone="blue">{LOCATION_KIND_LABELS[l.kind]}</Badge>
              {l.is_default && <Badge tone="violet">الافتراضي</Badge>}
              {!l.is_active && <Badge tone="slate">معطل</Badge>}
              <Badge tone="green">{num(stock[l.id] ?? 0)} قطعة</Badge>
            </div>
            {l.address && (
              <p className="mt-2 flex items-center gap-1 text-xs text-slate-500">
                <MapPin className="size-3.5" /> {l.address}
              </p>
            )}
          </Card>
        ))}
      </div>

      <Card>
        <div className="border-b border-slate-100 p-4">
          <h2 className="font-semibold text-slate-900">موقع كل موظف</h2>
          <p className="text-sm text-slate-500">
            الكاشير يبيع ويستلم ويشحن ويجرد في موقعه فقط. الوردية المفتوحة تأخذ موقع الموظف عند فتحها. بدون تعيين: الموقع الافتراضي.
          </p>
        </div>
        {staff.length === 0 ? (
          <EmptyState title="لا يوجد موظفون" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>الموظف</th>
                <th>الدور</th>
                <th>الموقع</th>
              </tr>
            </thead>
            <tbody>
              {staff.map((p) => (
                <tr key={p.id}>
                  <td className="font-medium">{p.full_name}</td>
                  <td>{ROLE_LABELS[p.role]}</td>
                  <td>
                    <Select
                      aria-label={`موقع ${p.full_name}`}
                      className="h-9 w-auto min-w-40"
                      value={assigned[p.id] ?? ""}
                      onChange={(e) => assign(p.id, e.target.value)}
                    >
                      <option value="">الافتراضي ({locations.find((l) => l.id === defaultId)?.name ?? "-"})</option>
                      {active.map((l) => (
                        <option key={l.id} value={l.id}>
                          {l.name}
                        </option>
                      ))}
                    </Select>
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      {edit && (
        <Modal
          open
          onClose={() => setEdit(null)}
          title={edit.id ? "تعديل موقع" : "موقع جديد"}
          size="sm"
          footer={
            <Button onClick={save} loading={busy}>
              حفظ
            </Button>
          }
        >
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <Field label="الرمز">
                <Input dir="ltr" value={edit.code} onChange={(e) => setEdit({ ...edit, code: e.target.value })} placeholder="BR2" />
              </Field>
              <Field label="النوع">
                <Select value={edit.kind} onChange={(e) => setEdit({ ...edit, kind: e.target.value as LocationKind })}>
                  <option value="store">فرع</option>
                  <option value="warehouse">مستودع</option>
                </Select>
              </Field>
            </div>
            <Field label="الاسم">
              <Input value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} placeholder="فرع العليا" />
            </Field>
            <Field label="العنوان">
              <Input value={edit.address} onChange={(e) => setEdit({ ...edit, address: e.target.value })} />
            </Field>
            <Field label="الهاتف">
              <Input dir="ltr" value={edit.phone} onChange={(e) => setEdit({ ...edit, phone: e.target.value })} />
            </Field>
            {edit.id && !locations.find((l) => l.id === edit.id)?.is_default && (
              <Checkbox label="نشط" checked={edit.is_active} onChange={(v) => setEdit({ ...edit, is_active: v })} />
            )}
            <p className="text-xs text-slate-500">لا يمكن تعطيل موقع فيه مخزون أو له تحويلات مفتوحة.</p>
          </div>
        </Modal>
      )}
    </div>
  );
}
