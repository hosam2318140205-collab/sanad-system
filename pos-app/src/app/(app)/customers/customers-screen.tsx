"use client";

import { Plus, Search } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, ConfirmDialog, EmptyState, Field, Input, Loading, Modal, PageHeader, Table, Textarea, useToast } from "@/components/ui";
import { SALE_STATUS_LABELS, dateOnly, dateTime, errorMessage, money } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Customer, Sale } from "@/lib/types";

const blank = { name: "", phone: "", email: "", vat_number: "", city: "", notes: "" };

export function CustomersScreen() {
  const toast = useToast();
  const { isManager } = useSession();
  const [rows, setRows] = useState<Customer[] | null>(null);
  const [q, setQ] = useState("");
  const [editing, setEditing] = useState<Customer | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [stats, setStats] = useState<{ invoices: number; total_spent: number; last_visit: string | null } | null>(null);
  const [history, setHistory] = useState<Sale[]>([]);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const load = useCallback(async () => {
    let req = supabase().from("customers").select("*").order("created_at", { ascending: false }).limit(200);
    const term = q.trim().replace(/[%,()]/g, "");
    if (term) req = req.or(`name.ilike.%${term}%,phone.ilike.%${term}%`);
    const { data, error } = await req;
    if (error) toast(errorMessage(error), "error");
    setRows((data ?? []) as Customer[]);
  }, [q, toast]);

  useEffect(() => {
    const t = setTimeout(load, 250);
    return () => clearTimeout(t);
  }, [load]);

  const openForm = async (c: Customer | null) => {
    setEditing(c);
    setForm(
      c
        ? { name: c.name, phone: c.phone ?? "", email: c.email ?? "", vat_number: c.vat_number ?? "", city: c.city ?? "", notes: c.notes ?? "" }
        : blank,
    );
    setStats(null);
    setHistory([]);
    setOpen(true);
    if (c) {
      const db = supabase();
      const [{ data: s }, { data: h }] = await Promise.all([
        db.rpc("customer_stats", { p_customer_id: c.id }),
        db.from("sales").select("*").eq("customer_id", c.id).order("created_at", { ascending: false }).limit(20),
      ]);
      setStats(s as typeof stats);
      setHistory((h ?? []) as Sale[]);
    }
  };

  const save = async () => {
    if (!form.name.trim()) return toast("الاسم مطلوب", "error");
    setBusy(true);
    const payload = Object.fromEntries(Object.entries(form).map(([k, v]) => [k, v.trim() || null]));
    const db = supabase().from("customers");
    const { error } = editing ? await db.update(payload).eq("id", editing.id) : await db.insert(payload);
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم الحفظ");
    setOpen(false);
    load();
  };

  const remove = async () => {
    if (!editing) return;
    const { error } = await supabase().from("customers").delete().eq("id", editing.id);
    setConfirmDelete(false);
    if (error) return toast(errorMessage(error), "error");
    setOpen(false);
    load();
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="العملاء"
        actions={
          <Button onClick={() => openForm(null)}>
            <Plus className="size-4" /> عميل جديد
          </Button>
        }
      />
      <Card>
        <div className="border-b border-slate-100 p-3">
          <div className="relative">
            <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <Input className="ps-9" placeholder="بحث بالاسم أو الجوال" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
        </div>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا يوجد عملاء" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>الاسم</th>
                <th>الجوال</th>
                <th>المدينة</th>
                <th>الرقم الضريبي</th>
                <th>تاريخ التسجيل</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.id} className="cursor-pointer" onClick={() => openForm(c)}>
                  <td className="font-medium">{c.name}</td>
                  <td className="ltr-nums">{c.phone ?? "-"}</td>
                  <td>{c.city ?? "-"}</td>
                  <td className="ltr-nums">{c.vat_number ?? "-"}</td>
                  <td className="ltr-nums">{dateOnly(c.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={editing ? editing.name : "عميل جديد"}
        size="lg"
        footer={
          <>
            {editing && isManager && (
              <Button variant="ghost" className="me-auto text-red-600" onClick={() => setConfirmDelete(true)}>
                حذف
              </Button>
            )}
            <Button onClick={save} loading={busy}>
              حفظ
            </Button>
          </>
        }
      >
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="الاسم *">
            <Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </Field>
          <Field label="الجوال">
            <Input dir="ltr" inputMode="tel" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
          </Field>
          <Field label="البريد">
            <Input dir="ltr" type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
          </Field>
          <Field label="المدينة">
            <Input value={form.city} onChange={(e) => setForm({ ...form, city: e.target.value })} />
          </Field>
          <Field label="الرقم الضريبي (B2B)">
            <Input dir="ltr" value={form.vat_number} onChange={(e) => setForm({ ...form, vat_number: e.target.value })} />
          </Field>
          <Field label="ملاحظات" className="sm:col-span-2">
            <Textarea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} placeholder="المقاس المفضل، ملاحظات التفصيل..." />
          </Field>
        </div>

        {editing && (
          <div className="mt-5 space-y-3">
            {stats && (
              <div className="grid grid-cols-3 gap-2 text-center">
                <div className="rounded-lg bg-slate-50 p-2">
                  <p className="text-xs text-slate-500">عدد الفواتير</p>
                  <p className="font-bold">{stats.invoices}</p>
                </div>
                <div className="rounded-lg bg-slate-50 p-2">
                  <p className="text-xs text-slate-500">إجمالي المشتريات</p>
                  <p className="font-bold">{money(stats.total_spent)}</p>
                </div>
                <div className="rounded-lg bg-slate-50 p-2">
                  <p className="text-xs text-slate-500">آخر زيارة</p>
                  <p className="ltr-nums font-bold">{dateOnly(stats.last_visit)}</p>
                </div>
              </div>
            )}
            {history.length > 0 && (
              <Table className="rounded-lg border border-slate-200">
                <thead>
                  <tr>
                    <th>الفاتورة</th>
                    <th>التاريخ</th>
                    <th>الإجمالي</th>
                    <th>الحالة</th>
                  </tr>
                </thead>
                <tbody>
                  {history.map((s) => (
                    <tr key={s.id}>
                      <td>
                        <Link href={`/sales/${s.id}`} className="text-brand-700 hover:underline">
                          {s.invoice_no}
                        </Link>
                      </td>
                      <td className="ltr-nums">{dateTime(s.created_at)}</td>
                      <td>{money(s.total)}</td>
                      <td>
                        <Badge>{SALE_STATUS_LABELS[s.status]}</Badge>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            )}
          </div>
        )}
      </Modal>
      <ConfirmDialog
        open={confirmDelete}
        title="حذف العميل"
        message="سيتم حذف العميل وتبقى فواتيره بدون عميل."
        tone="danger"
        confirmLabel="حذف"
        onConfirm={remove}
        onClose={() => setConfirmDelete(false)}
      />
    </div>
  );
}
