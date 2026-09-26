"use client";

import { useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Button, ConfirmDialog, Field, Input, Modal, Textarea, useToast } from "@/components/ui";
import { errorMessage } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Customer } from "@/lib/types";

const blank = { name: "", phone: "", email: "", vat_number: "", city: "", notes: "" };

/** إضافة/تعديل بيانات العميل (الحذف للمدير فقط — ويُمنع إن كان للعميل حساب ذمم أو نقاط). */
export function CustomerFormModal({
  open,
  customer,
  onClose,
  onSaved,
  onDeleted,
}: {
  open: boolean;
  customer: Customer | null;
  onClose: () => void;
  onSaved: (c: Customer) => void;
  onDeleted?: () => void;
}) {
  const toast = useToast();
  const { isManager } = useSession();
  const [form, setForm] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  useEffect(() => {
    if (!open) return;
    const c = customer;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reset form when the modal opens
    setForm(
      c
        ? { name: c.name, phone: c.phone ?? "", email: c.email ?? "", vat_number: c.vat_number ?? "", city: c.city ?? "", notes: c.notes ?? "" }
        : blank,
    );
  }, [open, customer]);

  const save = async () => {
    if (!form.name.trim()) return toast("الاسم مطلوب", "error");
    setBusy(true);
    const payload = Object.fromEntries(Object.entries(form).map(([k, v]) => [k, v.trim() || null]));
    const db = supabase().from("customers");
    const { data, error } = customer
      ? await db.update(payload).eq("id", customer.id).select().single()
      : await db.insert(payload).select().single();
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم الحفظ");
    onSaved(data as Customer);
  };

  const remove = async () => {
    if (!customer) return;
    const { error } = await supabase().from("customers").delete().eq("id", customer.id);
    setConfirmDelete(false);
    if (error) return toast(errorMessage(error), "error");
    onDeleted?.();
  };

  return (
    <>
      <Modal
        open={open}
        onClose={onClose}
        title={customer ? `تعديل: ${customer.name}` : "عميل جديد"}
        size="lg"
        footer={
          <>
            {customer && isManager && onDeleted && (
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
      </Modal>
      <ConfirmDialog
        open={confirmDelete}
        title="حذف العميل"
        message="سيتم حذف العميل وتبقى فواتيره بدون عميل. لا يمكن حذف عميل له حركات ذمم أو نقاط."
        tone="danger"
        confirmLabel="حذف"
        onConfirm={remove}
        onClose={() => setConfirmDelete(false)}
      />
    </>
  );
}
