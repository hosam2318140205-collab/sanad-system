"use client";

import { Download, Paperclip, Plus, Tags, Trash2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { RankBars } from "@/components/bar-chart";
import { useSession } from "@/components/session-context";
import { fetchMyOpenShift } from "@/components/shift-dialogs";
import { Badge, Button, Card, ConfirmDialog, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Stat, Table, Textarea, cn, useToast } from "@/components/ui";
import { downloadCsv } from "@/lib/csv";
import { EXPENSE_PAYMENT_LABELS, dateOnly, errorMessage, isoDay, money, num, round2 } from "@/lib/format";
import { presets } from "@/lib/periods";
import { supabase } from "@/lib/supabase/client";
import type { Expense, ExpenseCategory, ExpensePayment, ExpensesSummary } from "@/lib/types";

const RECEIPTS = "expense-receipts";

export function ExpensesScreen() {
  const toast = useToast();
  const [from, setFrom] = useState(() => presets()[3].from);
  const [to, setTo] = useState(() => presets()[3].to);
  const [rows, setRows] = useState<Expense[] | null>(null);
  const [summary, setSummary] = useState<ExpensesSummary | null>(null);
  const [categories, setCategories] = useState<ExpenseCategory[]>([]);
  const [catFilter, setCatFilter] = useState("");
  const [editing, setEditing] = useState<Expense | "new" | null>(null);
  const [showCats, setShowCats] = useState(false);
  const [receipt, setReceipt] = useState<{ url: string; isPdf: boolean } | null>(null);

  const loadCategories = useCallback(async () => {
    const { data } = await supabase().from("expense_categories").select("*").order("sort_order").order("name");
    setCategories((data ?? []) as ExpenseCategory[]);
  }, []);

  const load = useCallback(async () => {
    const db = supabase();
    let req = db.from("expenses").select("*").gte("expense_date", from).lte("expense_date", to).order("expense_date", { ascending: false }).order("created_at", { ascending: false });
    if (catFilter) req = req.eq("category_id", catFilter);
    const [{ data, error }, { data: s, error: sErr }] = await Promise.all([req, db.rpc("expenses_summary", { p_from: from, p_to: to })]);
    if (error || sErr) toast(errorMessage(error ?? sErr), "error");
    setRows((data ?? []) as Expense[]);
    setSummary((s as ExpensesSummary) ?? null);
  }, [from, to, catFilter, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    loadCategories();
  }, [loadCategories]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reload when filters change
    load();
  }, [load]);

  const catName = useMemo(() => new Map(categories.map((c) => [c.id, c.name])), [categories]);

  const openReceipt = async (path: string) => {
    const { data, error } = await supabase().storage.from(RECEIPTS).createSignedUrl(path, 300);
    if (error || !data) return toast(errorMessage(error), "error");
    setReceipt({ url: data.signedUrl, isPdf: path.toLowerCase().endsWith(".pdf") });
  };

  const exportCsv = () => {
    if (!rows) return;
    downloadCsv(
      `expenses-${from}_${to}.csv`,
      ["الرقم", "التاريخ", "التصنيف", "الجهة", "المرجع", "طريقة الدفع", "المبلغ", "الضريبة", "الصافي", "ملاحظات"],
      rows.map((e) => [
        e.expense_no,
        e.expense_date,
        catName.get(e.category_id) ?? "",
        e.payee ?? "",
        e.reference ?? "",
        EXPENSE_PAYMENT_LABELS[e.payment_method],
        Number(e.amount).toFixed(2),
        Number(e.vat_amount).toFixed(2),
        (Number(e.amount) - Number(e.vat_amount)).toFixed(2),
        e.notes ?? "",
      ]),
    );
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="المصروفات"
        subtitle="تُخصم من مجمل الربح لحساب صافي الربح في التقارير"
        actions={
          <>
            <Button variant="outline" onClick={() => setShowCats(true)}>
              <Tags className="size-4" /> التصنيفات
            </Button>
            <Button variant="outline" onClick={exportCsv} disabled={!rows?.length}>
              <Download className="size-4" /> CSV
            </Button>
            <Button onClick={() => setEditing("new")}>
              <Plus className="size-4" /> مصروف جديد
            </Button>
          </>
        }
      />

      <Card className="mb-4 flex flex-wrap items-center gap-2 p-3">
        {presets().map((p) => (
          <button
            key={p.key}
            onClick={() => {
              setFrom(p.from);
              setTo(p.to);
            }}
            className={cn("rounded-full px-3 py-1.5 text-sm", from === p.from && to === p.to ? "bg-slate-900 text-white" : "bg-slate-100 hover:bg-slate-200")}
          >
            {p.label}
          </button>
        ))}
        <div className="flex w-full items-center gap-2 sm:ms-auto sm:w-auto">
          <Input type="date" className="min-w-0 flex-1 sm:w-auto sm:flex-none" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="من تاريخ" />
          <span className="text-slate-400">—</span>
          <Input type="date" className="min-w-0 flex-1 sm:w-auto sm:flex-none" value={to} onChange={(e) => setTo(e.target.value)} aria-label="إلى تاريخ" />
        </div>
      </Card>

      {summary && (
        <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Stat label="إجمالي المصروفات" value={money(summary.total)} hint={`${num(summary.count)} مصروف`} tone="red" />
          <Stat label="الصافي (بدون الضريبة)" value={money(summary.net)} hint="يُخصم من الربح" />
          <Stat label="ضريبة المدخلات" value={money(summary.vat)} hint="من فواتير ضريبية" tone="amber" />
          <Stat label="مدفوع من الدرج" value={money(summary.from_drawer)} tone="blue" />
        </div>
      )}

      <div className="space-y-4">
        <Card className="p-4">
          <p className="mb-3 font-semibold">حسب التصنيف</p>
          {summary && summary.by_category.length > 0 ? (
            <RankBars data={summary.by_category.map((c) => ({ label: c.name, value: Number(c.total), hint: `${c.count}` }))} format={money} />
          ) : (
            <p className="py-6 text-center text-sm text-slate-500">لا توجد مصروفات في الفترة</p>
          )}
        </Card>

        <Card>
          <div className="border-b border-slate-100 p-3">
            <Select className="w-full sm:w-auto" value={catFilter} onChange={(e) => setCatFilter(e.target.value)} aria-label="التصنيف">
              <option value="">كل التصنيفات</option>
              {categories.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </Select>
          </div>
          {rows === null ? (
            <Loading />
          ) : rows.length === 0 ? (
            <EmptyState title="لا توجد مصروفات">
              <button className="text-sm text-brand-700 hover:underline" onClick={() => setEditing("new")}>
                سجّل أول مصروف
              </button>
            </EmptyState>
          ) : (
            <>
              {/* الجوال: بطاقات */}
              <ul className="divide-y divide-slate-100 md:hidden">
                {rows.map((e) => (
                  <li key={e.id} className="flex items-start gap-3 p-3" onClick={() => setEditing(e)}>
                    <div className="min-w-0 flex-1">
                      <p className="font-medium">{catName.get(e.category_id)}</p>
                      <p className="break-words text-xs text-slate-500">
                        {dateOnly(e.expense_date)} · {EXPENSE_PAYMENT_LABELS[e.payment_method]}
                        {e.payee ? ` · ${e.payee}` : ""}
                      </p>
                    </div>
                    <div className="shrink-0 text-end">
                      <p className="font-semibold text-red-600">{money(e.amount)}</p>
                      {e.receipt_path && <Paperclip className="ms-auto mt-1 size-4 text-slate-400" />}
                    </div>
                  </li>
                ))}
              </ul>
              {/* الكمبيوتر: جدول */}
              <Table className="hidden md:block">
                <thead>
                  <tr>
                    <th>التاريخ</th>
                    <th>التصنيف</th>
                    <th>الجهة</th>
                    <th>الدفع</th>
                    <th>المبلغ</th>
                    <th>الضريبة</th>
                    <th>إيصال</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((e) => (
                    <tr key={e.id} className="cursor-pointer" onClick={() => setEditing(e)}>
                      <td className="ltr-nums">{dateOnly(e.expense_date)}</td>
                      <td className="font-medium">{catName.get(e.category_id)}</td>
                      <td className="max-w-48 truncate">{e.payee ?? "-"}</td>
                      <td>
                        <Badge tone={e.payment_method === "cash_drawer" ? "blue" : "slate"}>{EXPENSE_PAYMENT_LABELS[e.payment_method]}</Badge>
                      </td>
                      <td className="font-semibold text-red-600">{money(e.amount)}</td>
                      <td>{Number(e.vat_amount) > 0 ? money(e.vat_amount) : "-"}</td>
                      <td>
                        {e.receipt_path ? (
                          <button
                            className="text-brand-700 hover:underline"
                            onClick={(ev) => {
                              ev.stopPropagation();
                              openReceipt(e.receipt_path!);
                            }}
                          >
                            عرض
                          </button>
                        ) : (
                          "-"
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            </>
          )}
        </Card>
      </div>

      {editing && (
        <ExpenseForm
          expense={editing === "new" ? null : editing}
          categories={categories}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            load();
          }}
          onViewReceipt={openReceipt}
        />
      )}
      <ExpenseCategoriesModal open={showCats} categories={categories} onClose={() => setShowCats(false)} onChanged={loadCategories} />
      <Modal open={!!receipt} onClose={() => setReceipt(null)} title="الإيصال" size="lg">
        {receipt &&
          (receipt.isPdf ? (
            <a href={receipt.url} target="_blank" rel="noreferrer" className="text-brand-700 hover:underline">
              فتح ملف PDF
            </a>
          ) : (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={receipt.url} alt="الإيصال" className="mx-auto max-h-[70vh] rounded-lg" />
          ))}
      </Modal>
    </div>
  );
}

function ExpenseForm({
  expense,
  categories,
  onClose,
  onSaved,
  onViewReceipt,
}: {
  expense: Expense | null;
  categories: ExpenseCategory[];
  onClose: () => void;
  onSaved: () => void;
  onViewReceipt: (path: string) => void;
}) {
  const toast = useToast();
  const { settings, profile } = useSession();
  const locked = expense?.payment_method === "cash_drawer";
  const [f, setF] = useState({
    category_id: expense?.category_id ?? "",
    expense_date: expense?.expense_date ?? isoDay(),
    amount: expense ? String(expense.amount) : "",
    vat_amount: expense ? String(expense.vat_amount) : "",
    payment_method: (expense?.payment_method ?? "cash") as ExpensePayment,
    payee: expense?.payee ?? "",
    reference: expense?.reference ?? "",
    notes: expense?.notes ?? "",
  });
  const [file, setFile] = useState<File | null>(null);
  const [hasShift, setHasShift] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  useEffect(() => {
    fetchMyOpenShift(profile.id).then((s) => setHasShift(!!s));
  }, [profile.id]);

  const set = <K extends keyof typeof f>(k: K, v: (typeof f)[K]) => setF((p) => ({ ...p, [k]: v }));
  const vatRate = Number(settings.vat_rate);

  const save = async () => {
    if (!f.category_id) return toast("اختر التصنيف", "error");
    if (!(Number(f.amount) > 0)) return toast("أدخل المبلغ", "error");
    if (Number(f.vat_amount || 0) > Number(f.amount)) return toast("الضريبة لا تتجاوز المبلغ", "error");
    setBusy(true);
    const db = supabase();
    try {
      const payload = {
        category_id: f.category_id,
        expense_date: f.expense_date,
        vat_amount: round2(Number(f.vat_amount || 0)),
        payee: f.payee.trim() || null,
        reference: f.reference.trim() || null,
        notes: f.notes.trim() || null,
        ...(locked ? {} : { amount: round2(Number(f.amount)), payment_method: f.payment_method }),
      };
      let id = expense?.id;
      if (id) {
        const { error } = await db.from("expenses").update(payload).eq("id", id);
        if (error) throw error;
      } else {
        const { data, error } = await db.from("expenses").insert(payload).select("id").single();
        if (error) throw error;
        id = (data as { id: string }).id;
      }
      if (file) {
        const ext = file.name.split(".").pop()?.toLowerCase() || "jpg";
        const path = `expenses/${id}-${Date.now()}.${ext}`;
        const { error: upErr } = await db.storage.from(RECEIPTS).upload(path, file, { contentType: file.type });
        if (upErr) throw new Error(`حُفظ المصروف لكن تعذر رفع الإيصال: ${errorMessage(upErr)}`);
        const { error } = await db.from("expenses").update({ receipt_path: path }).eq("id", id);
        if (error) throw error;
        if (expense?.receipt_path) await db.storage.from(RECEIPTS).remove([expense.receipt_path]);
      }
      toast(expense ? "تم تحديث المصروف" : "تم تسجيل المصروف");
      onSaved();
    } catch (e) {
      toast(errorMessage(e), "error");
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!expense) return;
    setBusy(true);
    const { error } = await supabase().from("expenses").delete().eq("id", expense.id);
    if (error) {
      setBusy(false);
      setConfirmDelete(false);
      return toast(errorMessage(error), "error");
    }
    if (expense.receipt_path) await supabase().storage.from(RECEIPTS).remove([expense.receipt_path]);
    toast("تم حذف المصروف");
    onSaved();
  };

  return (
    <Modal
      open
      onClose={onClose}
      title={expense ? `مصروف ${expense.expense_no}` : "مصروف جديد"}
      footer={
        <>
          {expense && (
            <Button variant="ghost" className="me-auto text-red-600" onClick={() => setConfirmDelete(true)}>
              <Trash2 className="size-4" /> حذف
            </Button>
          )}
          <Button onClick={save} loading={busy}>
            حفظ
          </Button>
        </>
      }
    >
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="التصنيف *">
          <Select value={f.category_id} onChange={(e) => set("category_id", e.target.value)}>
            <option value="">اختر</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="التاريخ">
          <Input type="date" value={f.expense_date} onChange={(e) => set("expense_date", e.target.value)} />
        </Field>
        <Field label="المبلغ المدفوع (شامل الضريبة) *" hint={locked ? "مدفوع من الدرج — لتغييره احذف المصروف وأعد إدخاله" : undefined}>
          <Input type="number" inputMode="decimal" min={0} step="0.01" value={f.amount} disabled={locked} onChange={(e) => set("amount", e.target.value)} />
        </Field>
        <Field label="ضريبة المدخلات" hint="فقط إن كانت لديك فاتورة ضريبية">
          <div className="flex gap-2">
            <Input type="number" inputMode="decimal" min={0} step="0.01" className="min-w-0 flex-1" value={f.vat_amount} onChange={(e) => set("vat_amount", e.target.value)} placeholder="0" />
            <Button
              type="button"
              variant="outline"
              className="shrink-0"
              disabled={!(Number(f.amount) > 0)}
              onClick={() => set("vat_amount", round2((Number(f.amount) * vatRate) / (100 + vatRate)).toFixed(2))}
            >
              {vatRate}%
            </Button>
          </div>
        </Field>
        <Field label="طريقة الدفع" className="sm:col-span-2">
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            {(Object.keys(EXPENSE_PAYMENT_LABELS) as ExpensePayment[]).map((m) => {
              const drawerUnavailable = m === "cash_drawer" && !locked && hasShift === false;
              return (
                <button
                  key={m}
                  type="button"
                  disabled={locked || drawerUnavailable}
                  onClick={() => set("payment_method", m)}
                  className={cn(
                    "rounded-lg border-2 px-2 py-2 text-sm",
                    f.payment_method === m ? "border-brand-700 bg-brand-50 font-medium text-brand-800" : "border-slate-200",
                    (locked || drawerUnavailable) && f.payment_method !== m && "opacity-40",
                  )}
                  title={drawerUnavailable ? "افتح وردية للدفع من الدرج" : undefined}
                >
                  {EXPENSE_PAYMENT_LABELS[m]}
                </button>
              );
            })}
          </div>
          {f.payment_method === "cash_drawer" && !locked && (
            <span className="mt-1 block text-xs text-slate-500">سيُسجَّل تلقائياً كسحب من ورديتك المفتوحة.</span>
          )}
          {hasShift === false && !locked && <span className="mt-1 block text-xs text-slate-500">الدفع من الدرج يتطلب وردية مفتوحة.</span>}
        </Field>
        <Field label="الجهة المستفيدة">
          <Input value={f.payee} onChange={(e) => set("payee", e.target.value)} placeholder="المؤجر، شركة الكهرباء..." />
        </Field>
        <Field label="رقم الفاتورة / المرجع">
          <Input dir="ltr" value={f.reference} onChange={(e) => set("reference", e.target.value)} />
        </Field>
        <Field label="ملاحظات" className="sm:col-span-2">
          <Textarea className="min-h-16" value={f.notes} onChange={(e) => set("notes", e.target.value)} />
        </Field>
        <div className="space-y-2 sm:col-span-2">
          <p className="text-sm font-medium text-slate-700">صورة الإيصال (اختياري)</p>
          <div className="flex flex-wrap items-center gap-2">
            <label className="inline-flex h-10 cursor-pointer items-center gap-2 rounded-lg border border-slate-300 bg-white px-4 text-sm hover:bg-slate-50">
              <Paperclip className="size-4" /> {file ? file.name : expense?.receipt_path ? "استبدال الإيصال" : "إرفاق صورة / PDF"}
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,application/pdf"
                className="hidden"
                onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              />
            </label>
            {expense?.receipt_path && !file && (
              <Button type="button" variant="ghost" size="sm" onClick={() => onViewReceipt(expense.receipt_path!)}>
                عرض الإيصال الحالي
              </Button>
            )}
          </div>
        </div>
      </div>
      <ConfirmDialog
        open={confirmDelete}
        title="حذف المصروف"
        message={locked ? "سيُحذف المصروف وحركة السحب المرتبطة به من الوردية." : "سيُحذف المصروف وإيصاله."}
        tone="danger"
        confirmLabel="حذف"
        loading={busy}
        onConfirm={remove}
        onClose={() => setConfirmDelete(false)}
      />
    </Modal>
  );
}

function ExpenseCategoriesModal({
  open,
  categories,
  onClose,
  onChanged,
}: {
  open: boolean;
  categories: ExpenseCategory[];
  onClose: () => void;
  onChanged: () => void;
}) {
  const toast = useToast();
  const [name, setName] = useState("");
  const [toDelete, setToDelete] = useState<ExpenseCategory | null>(null);

  const add = async () => {
    if (!name.trim()) return;
    const { error } = await supabase().from("expense_categories").insert({ name: name.trim(), sort_order: categories.length + 1 });
    if (error) return toast(errorMessage(error), "error");
    setName("");
    onChanged();
  };
  const rename = async (c: ExpenseCategory, v: string) => {
    if (!v.trim() || v === c.name) return;
    const { error } = await supabase().from("expense_categories").update({ name: v.trim() }).eq("id", c.id);
    if (error) toast(errorMessage(error), "error");
    else onChanged();
  };
  const remove = async () => {
    if (!toDelete) return;
    const { error } = await supabase().from("expense_categories").delete().eq("id", toDelete.id);
    setToDelete(null);
    if (error) toast(errorMessage(error), "error");
    else onChanged();
  };

  return (
    <Modal open={open} onClose={onClose} title="تصنيفات المصروفات">
      <div className="space-y-3">
        <div className="flex gap-2">
          <Input placeholder="تصنيف جديد" value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add()} />
          <Button onClick={add}>إضافة</Button>
        </div>
        <ul className="divide-y divide-slate-100">
          {categories.map((c) => (
            <li key={c.id} className="flex items-center gap-2 py-2">
              <Input defaultValue={c.name} onBlur={(e) => rename(c, e.target.value)} className="h-9" />
              <button className="p-2 text-slate-400 hover:text-red-600" onClick={() => setToDelete(c)} aria-label="حذف">
                <Trash2 className="size-4" />
              </button>
            </li>
          ))}
        </ul>
      </div>
      <ConfirmDialog
        open={!!toDelete}
        title="حذف التصنيف"
        message={`حذف "${toDelete?.name}"؟ لا يمكن حذف تصنيف عليه مصروفات مسجلة.`}
        tone="danger"
        confirmLabel="حذف"
        onConfirm={remove}
        onClose={() => setToDelete(null)}
      />
    </Modal>
  );
}
