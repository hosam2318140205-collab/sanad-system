"use client";

import { Pencil, Plus, Search } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { Badge, Button, Card, Checkbox, EmptyState, Field, Input, Loading, Modal, PageHeader, Table, Textarea, useToast } from "@/components/ui";
import { errorMessage, money } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Supplier } from "@/lib/types";

type Row = Supplier & { purchases: { total: number; status: string }[]; balance: { balance: number } | null };

const blank = {
  name: "", contact_name: "", phone: "", email: "", vat_number: "", address: "", notes: "", is_active: true,
  code: "", payment_terms_days: "0", credit_limit: "", iban: "", vat_registered: true, lead_time_days: "",
};

export function SuppliersScreen() {
  const toast = useToast();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [q, setQ] = useState("");
  const [editing, setEditing] = useState<Supplier | null>(null);
  const [form, setForm] = useState(blank);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase()
      .from("suppliers")
      .select("*, purchases:purchase_orders(total, status), balance:supplier_balances(balance)")
      .order("name");
    if (error) toast(errorMessage(error), "error");
    setRows((data ?? []) as Row[]);
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const openForm = (s: Supplier | null) => {
    setEditing(s);
    setForm(
      s
        ? {
            name: s.name,
            contact_name: s.contact_name ?? "",
            phone: s.phone ?? "",
            email: s.email ?? "",
            vat_number: s.vat_number ?? "",
            address: s.address ?? "",
            notes: s.notes ?? "",
            is_active: s.is_active,
            code: s.code ?? "",
            payment_terms_days: String(s.payment_terms_days ?? 0),
            credit_limit: s.credit_limit == null ? "" : String(s.credit_limit),
            iban: s.iban ?? "",
            vat_registered: s.vat_registered ?? true,
            lead_time_days: s.lead_time_days == null ? "" : String(s.lead_time_days),
          }
        : blank,
    );
    setOpen(true);
  };

  const save = async () => {
    if (!form.name.trim()) return toast("اسم المورد مطلوب", "error");
    setBusy(true);
    const payload = {
      ...Object.fromEntries(Object.entries(form).map(([k, v]) => [k, typeof v === "string" ? v.trim() || null : v])),
      payment_terms_days: Math.max(0, Math.floor(Number(form.payment_terms_days) || 0)),
      credit_limit: form.credit_limit.trim() === "" ? null : Number(form.credit_limit),
      lead_time_days: form.lead_time_days.trim() === "" ? null : Math.floor(Number(form.lead_time_days)),
    };
    const db = supabase().from("suppliers");
    const { error } = editing ? await db.update(payload).eq("id", editing.id) : await db.insert(payload);
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم الحفظ");
    setOpen(false);
    load();
  };

  const list = (rows ?? []).filter(
    (s) => !q.trim() || s.name.includes(q.trim()) || s.phone?.includes(q.trim()) || s.contact_name?.includes(q.trim()),
  );

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="الموردون"
        actions={
          <Button onClick={() => openForm(null)}>
            <Plus className="size-4" /> مورد جديد
          </Button>
        }
      />
      <Card>
        <div className="border-b border-slate-100 p-3">
          <div className="relative">
            <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <Input className="ps-9" placeholder="بحث" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
        </div>
        {rows === null ? (
          <Loading />
        ) : list.length === 0 ? (
          <EmptyState title="لا يوجد موردون" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>المورد</th>
                <th>المسؤول</th>
                <th>الجوال</th>
                <th>الرقم الضريبي</th>
                <th>إجمالي المشتريات</th>
                <th>الرصيد (علينا)</th>
                <th>الحالة</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {list.map((s) => (
                <tr key={s.id}>
                  <td>
                    <Link href={`/suppliers/${s.id}`} className="font-medium text-brand-700 hover:underline">
                      {s.name}
                    </Link>
                    {s.payment_terms_days ? <span className="block text-xs text-slate-500">سداد {s.payment_terms_days} يوماً</span> : null}
                  </td>
                  <td>{s.contact_name ?? "-"}</td>
                  <td className="ltr-nums">{s.phone ?? "-"}</td>
                  <td className="ltr-nums">{s.vat_number ?? "-"}</td>
                  <td>{money(s.purchases.filter((p) => p.status === "received").reduce((sum, p) => sum + Number(p.total), 0))}</td>
                  <td className={Number(s.balance?.balance ?? 0) > 0 ? "font-semibold text-amber-700" : ""}>{money(s.balance?.balance ?? 0)}</td>
                  <td>{s.is_active ? <Badge tone="green">نشط</Badge> : <Badge>موقوف</Badge>}</td>
                  <td>
                    <Button size="sm" variant="ghost" aria-label={`تعديل ${s.name}`} onClick={() => openForm(s)}>
                      <Pencil className="size-4" />
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={editing ? "تعديل مورد" : "مورد جديد"}
        footer={
          <Button onClick={save} loading={busy}>
            حفظ
          </Button>
        }
      >
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="اسم المورد *" className="sm:col-span-2">
            <Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </Field>
          <Field label="اسم المسؤول">
            <Input value={form.contact_name} onChange={(e) => setForm({ ...form, contact_name: e.target.value })} />
          </Field>
          <Field label="الجوال">
            <Input dir="ltr" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
          </Field>
          <Field label="البريد">
            <Input dir="ltr" type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
          </Field>
          <Field label="الرقم الضريبي">
            <Input dir="ltr" value={form.vat_number} onChange={(e) => setForm({ ...form, vat_number: e.target.value })} />
          </Field>
          <Field label="العنوان" className="sm:col-span-2">
            <Input value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} />
          </Field>
          <Field label="ملاحظات" className="sm:col-span-2">
            <Textarea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
          </Field>
          <Field label="رمز المورد">
            <Input dir="ltr" value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} />
          </Field>
          <Field label="مدة السداد (يوم، 0 = نقدي)">
            <Input type="number" min={0} value={form.payment_terms_days} onChange={(e) => setForm({ ...form, payment_terms_days: e.target.value })} />
          </Field>
          <Field label="حد الائتمان">
            <Input type="number" min={0} value={form.credit_limit} onChange={(e) => setForm({ ...form, credit_limit: e.target.value })} />
          </Field>
          <Field label="مدة التوريد المتفق عليها (يوم)">
            <Input type="number" min={0} value={form.lead_time_days} onChange={(e) => setForm({ ...form, lead_time_days: e.target.value })} />
          </Field>
          <Field label="IBAN" className="sm:col-span-2">
            <Input dir="ltr" value={form.iban} onChange={(e) => setForm({ ...form, iban: e.target.value })} />
          </Field>
          <Checkbox label="مسجل في ضريبة القيمة المضافة (فواتيره عليها ضريبة مدخلات)" checked={form.vat_registered} onChange={(v) => setForm({ ...form, vat_registered: v })} />
          <Checkbox label="نشط" checked={form.is_active} onChange={(v) => setForm({ ...form, is_active: v })} />
        </div>
      </Modal>
    </div>
  );
}
