"use client";

import { KeyRound, UserPlus } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, Field, Input, Loading, Modal, PageHeader, Select, Table, useToast } from "@/components/ui";
import { ROLE_LABELS, dateOnly, errorMessage } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Profile, UserRole } from "@/lib/types";
import { createStaffUser, resetStaffPassword } from "./actions";

const PERMISSIONS: Record<UserRole, string> = {
  owner: "كل الصلاحيات: الإعدادات، المستخدمون، سجل التدقيق، حذف البيانات",
  manager: "المنتجات، المخزون، المشتريات، الموردون، التقارير، كل الفواتير",
  cashier: "البيع، المرتجعات (حسب الإعداد)، العملاء، فواتيره فقط، إدخال الجرد",
};

export function UsersScreen() {
  const toast = useToast();
  const { profile: me } = useSession();
  const [rows, setRows] = useState<Profile[] | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ full_name: "", email: "", password: "", role: "cashier" as UserRole });
  const [busy, setBusy] = useState(false);
  const [pwUser, setPwUser] = useState<Profile | null>(null);
  const [newPw, setNewPw] = useState("");

  const load = useCallback(async () => {
    const { data, error } = await supabase().from("profiles").select("*").order("created_at");
    if (error) toast(errorMessage(error), "error");
    setRows((data ?? []) as Profile[]);
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const update = async (p: Profile, patch: Partial<Profile>) => {
    const { error } = await supabase().from("profiles").update(patch).eq("id", p.id);
    if (error) return toast(errorMessage(error), "error");
    toast("تم التحديث");
    load();
  };

  const create = async () => {
    setBusy(true);
    const res = await createStaffUser(form);
    setBusy(false);
    if (!res.ok) return toast(res.error, "error");
    toast("تم إنشاء المستخدم");
    setOpen(false);
    setForm({ full_name: "", email: "", password: "", role: "cashier" });
    load();
  };

  const resetPw = async () => {
    if (!pwUser) return;
    setBusy(true);
    const res = await resetStaffPassword(pwUser.id, newPw);
    setBusy(false);
    if (!res.ok) return toast(res.error, "error");
    toast("تم تغيير كلمة المرور");
    setPwUser(null);
    setNewPw("");
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="المستخدمون والصلاحيات"
        actions={
          <Button onClick={() => setOpen(true)}>
            <UserPlus className="size-4" /> مستخدم جديد
          </Button>
        }
      />

      <div className="mb-4 grid gap-3 md:grid-cols-3">
        {(Object.keys(PERMISSIONS) as UserRole[]).map((r) => (
          <Card key={r} className="p-3 text-sm">
            <p className="font-semibold">{ROLE_LABELS[r]}</p>
            <p className="text-slate-600">{PERMISSIONS[r]}</p>
          </Card>
        ))}
      </div>

      <Card>
        {rows === null ? (
          <Loading />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>الاسم</th>
                <th>البريد</th>
                <th>الصلاحية</th>
                <th>الحالة</th>
                <th>تاريخ الإضافة</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => {
                const self = p.id === me.id;
                return (
                  <tr key={p.id}>
                    <td className="font-medium">
                      {p.full_name} {self && <Badge tone="blue">أنت</Badge>}
                    </td>
                    <td className="ltr-nums">{p.email}</td>
                    <td>
                      <Select className="h-9 w-32" value={p.role} disabled={self} onChange={(e) => update(p, { role: e.target.value as UserRole })}>
                        {(Object.keys(ROLE_LABELS) as UserRole[]).map((r) => (
                          <option key={r} value={r}>
                            {ROLE_LABELS[r]}
                          </option>
                        ))}
                      </Select>
                    </td>
                    <td>
                      <button disabled={self} onClick={() => update(p, { is_active: !p.is_active })}>
                        {p.is_active ? <Badge tone="green">مفعل</Badge> : <Badge tone="red">موقوف — اضغط للتفعيل</Badge>}
                      </button>
                    </td>
                    <td className="ltr-nums">{dateOnly(p.created_at)}</td>
                    <td>
                      <Button size="sm" variant="ghost" onClick={() => setPwUser(p)}>
                        <KeyRound className="size-4" /> كلمة المرور
                      </Button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="مستخدم جديد"
        size="sm"
        footer={
          <Button onClick={create} loading={busy}>
            إنشاء
          </Button>
        }
      >
        <div className="space-y-3">
          <Field label="الاسم">
            <Input value={form.full_name} onChange={(e) => setForm({ ...form, full_name: e.target.value })} />
          </Field>
          <Field label="البريد الإلكتروني">
            <Input dir="ltr" type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
          </Field>
          <Field label="كلمة المرور" hint="8 أحرف على الأقل">
            <Input dir="ltr" type="password" value={form.password} onChange={(e) => setForm({ ...form, password: e.target.value })} />
          </Field>
          <Field label="الصلاحية">
            <Select value={form.role} onChange={(e) => setForm({ ...form, role: e.target.value as UserRole })}>
              {(Object.keys(ROLE_LABELS) as UserRole[]).map((r) => (
                <option key={r} value={r}>
                  {ROLE_LABELS[r]}
                </option>
              ))}
            </Select>
          </Field>
        </div>
      </Modal>

      <Modal
        open={!!pwUser}
        onClose={() => setPwUser(null)}
        title={`كلمة مرور جديدة — ${pwUser?.full_name ?? ""}`}
        size="sm"
        footer={
          <Button onClick={resetPw} loading={busy}>
            حفظ
          </Button>
        }
      >
        <Input dir="ltr" type="password" value={newPw} onChange={(e) => setNewPw(e.target.value)} placeholder="8 أحرف على الأقل" />
      </Modal>
    </div>
  );
}
