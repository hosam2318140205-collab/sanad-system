"use client";

import { BadgePercent, Plus } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Badge, Button, Card, Checkbox, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Table, Textarea, useToast } from "@/components/ui";
import { PROMO_KIND_LABELS } from "@/lib/customers";
import { dateTime, errorMessage, money } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Category, PromoKind, PromoScope, Promotion } from "@/lib/types";

type Row = Promotion & { category: { name: string } | null; product: { name: string } | null };

function promoState(p: Promotion, now: number): { label: string; tone: "green" | "slate" | "amber" | "red" } {
  if (!p.is_active) return { label: "موقوف", tone: "slate" };
  if (p.starts_at && new Date(p.starts_at).getTime() > now) return { label: "مجدول", tone: "amber" };
  if (p.ends_at && new Date(p.ends_at).getTime() <= now) return { label: "منتهي", tone: "red" };
  return { label: "ساري", tone: "green" };
}

function describe(p: Row): string {
  const target = p.scope === "all" ? "كل الأصناف" : p.scope === "category" ? `تصنيف ${p.category?.name ?? ""}` : `منتج ${p.product?.name ?? ""}`;
  const what =
    p.kind === "percent"
      ? `خصم ${Number(p.value)}%`
      : p.kind === "amount"
        ? `خصم ${money(p.value)} للقطعة`
        : `اشترِ ${p.buy_qty} واحصل على ${p.get_qty} مجاناً (الأرخص)`;
  return `${what} على ${target}${p.min_qty > 1 ? ` — عند شراء ${p.min_qty} قطع فأكثر` : ""}`;
}

const toLocal = (iso: string | null) => (iso ? new Date(new Date(iso).getTime() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16) : "");

export function PromotionsScreen() {
  const toast = useToast();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [editing, setEditing] = useState<Row | "new" | null>(null);
  const [now, setNow] = useState(0);

  const load = useCallback(async () => {
    const { data, error } = await supabase()
      .from("promotions")
      .select("*, category:categories(name), product:products(name)")
      .order("created_at", { ascending: false });
    if (error) toast(errorMessage(error), "error");
    setRows((data ?? []) as Row[]);
    setNow(Date.now());
  }, [toast]);

  useEffect(() => {
    (async () => {
      await load();
    })();
  }, [load]);

  const toggle = async (p: Row) => {
    const { error } = await supabase().from("promotions").update({ is_active: !p.is_active }).eq("id", p.id);
    if (error) return toast(errorMessage(error), "error");
    load();
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="العروض والخصومات"
        subtitle="تُطبق تلقائياً في نقطة البيع (الأفضل للعميل، بلا تراكب على نفس القطعة). الكوبون لا يُطبق إلا بإدخال رمزه."
        actions={
          <Button onClick={() => setEditing("new")}>
            <Plus className="size-4" /> عرض جديد
          </Button>
        }
      />
      {rows === null ? (
        <Loading />
      ) : rows.length === 0 ? (
        <Card>
          <EmptyState title="لا توجد عروض">أنشئ عرضاً بنسبة أو مبلغ أو «اشترِ 2 واحصل على 1».</EmptyState>
        </Card>
      ) : (
        <Card>
          <Table>
            <thead>
              <tr>
                <th>العرض</th>
                <th>التفاصيل</th>
                <th>الكوبون</th>
                <th>الصلاحية</th>
                <th>الحالة</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => {
                const st = promoState(p, now);
                return (
                  <tr key={p.id}>
                    <td className="font-medium">
                      <BadgePercent className="me-1 inline size-4 text-brand-700" />
                      {p.name}
                    </td>
                    <td className="max-w-80 whitespace-normal text-slate-600">{describe(p)}</td>
                    <td dir="ltr">{p.code ?? "—"}</td>
                    <td className="ltr-nums text-xs text-slate-600">
                      {p.starts_at ? dateTime(p.starts_at) : "الآن"} ← {p.ends_at ? dateTime(p.ends_at) : "مفتوح"}
                    </td>
                    <td>
                      <Badge tone={st.tone}>{st.label}</Badge>
                    </td>
                    <td className="whitespace-nowrap">
                      <button className="me-3 text-xs text-brand-700 hover:underline" onClick={() => setEditing(p)}>
                        تعديل
                      </button>
                      <button className="text-xs text-slate-600 hover:underline" onClick={() => toggle(p)}>
                        {p.is_active ? "إيقاف" : "تفعيل"}
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        </Card>
      )}
      {editing && (
        <PromotionForm
          promo={editing === "new" ? null : editing}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            load();
          }}
        />
      )}
    </div>
  );
}

function PromotionForm({ promo, onClose, onSaved }: { promo: Row | null; onClose: () => void; onSaved: () => void }) {
  const toast = useToast();
  const [categories, setCategories] = useState<Category[]>([]);
  const [products, setProducts] = useState<Array<{ id: string; name: string }>>([]);
  const [f, setF] = useState({
    name: promo?.name ?? "",
    kind: (promo?.kind ?? "percent") as PromoKind,
    value: promo ? String(promo.value) : "",
    buy_qty: String(promo?.buy_qty ?? 2),
    get_qty: String(promo?.get_qty ?? 1),
    scope: (promo?.scope ?? "all") as PromoScope,
    category_id: promo?.category_id ?? "",
    product_id: promo?.product_id ?? "",
    min_qty: String(promo?.min_qty ?? 1),
    code: promo?.code ?? "",
    starts_at: toLocal(promo?.starts_at ?? null),
    ends_at: toLocal(promo?.ends_at ?? null),
    is_active: promo?.is_active ?? true,
    notes: promo?.notes ?? "",
  });
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const db = supabase();
    db.from("categories").select("*").order("sort_order").then(({ data }) => setCategories((data ?? []) as Category[]));
    db.from("products").select("id, name").eq("is_active", true).order("name").then(({ data }) => setProducts((data ?? []) as typeof products));
  }, []);

  const save = async () => {
    if (!f.name.trim()) return toast("اسم العرض مطلوب", "error");
    setBusy(true);
    const payload = {
      name: f.name.trim(),
      kind: f.kind,
      value: f.kind === "bxgy" ? 0 : Number(f.value),
      buy_qty: f.kind === "bxgy" ? Number(f.buy_qty) : null,
      get_qty: f.kind === "bxgy" ? Number(f.get_qty) : null,
      scope: f.scope,
      category_id: f.scope === "category" ? f.category_id || null : null,
      product_id: f.scope === "product" ? f.product_id || null : null,
      min_qty: Math.max(1, Number(f.min_qty) || 1),
      code: f.code.trim() || null,
      starts_at: f.starts_at ? new Date(f.starts_at).toISOString() : null,
      ends_at: f.ends_at ? new Date(f.ends_at).toISOString() : null,
      is_active: f.is_active,
      notes: f.notes.trim() || null,
    };
    const db = supabase().from("promotions");
    const { error } = promo ? await db.update(payload).eq("id", promo.id) : await db.insert(payload);
    setBusy(false);
    if (error) {
      const msg = errorMessage(error);
      return toast(
        msg.includes("promo_value")
          ? "قيمة العرض غير صحيحة (النسبة بين 1 و100)"
          : msg.includes("promo_scope_target")
            ? "اختر التصنيف أو المنتج"
            : msg.includes("promo_code_format")
              ? "رمز الكوبون: 3–30 حرفاً إنجليزياً أو رقماً"
              : msg.includes("promo_dates")
                ? "تاريخ الانتهاء يجب أن يكون بعد البداية"
                : msg,
        "error",
      );
    }
    toast("تم حفظ العرض");
    onSaved();
  };

  return (
    <Modal open onClose={onClose} title={promo ? `تعديل: ${promo.name}` : "عرض جديد"} size="lg" footer={<Button onClick={save} loading={busy}>حفظ</Button>}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="اسم العرض *" className="sm:col-span-2">
          <Input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="تخفيضات الصيف" aria-label="اسم العرض" />
        </Field>
        <Field label="نوع العرض">
          <Select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as PromoKind })} aria-label="نوع العرض">
            {(Object.keys(PROMO_KIND_LABELS) as PromoKind[]).map((k) => (
              <option key={k} value={k}>
                {PROMO_KIND_LABELS[k]}
              </option>
            ))}
          </Select>
        </Field>
        {f.kind === "bxgy" ? (
          <div className="grid grid-cols-2 gap-2">
            <Field label="اشترِ">
              <Input type="number" min={1} value={f.buy_qty} onChange={(e) => setF({ ...f, buy_qty: e.target.value })} />
            </Field>
            <Field label="واحصل مجاناً على">
              <Input type="number" min={1} value={f.get_qty} onChange={(e) => setF({ ...f, get_qty: e.target.value })} />
            </Field>
          </div>
        ) : (
          <Field label={f.kind === "percent" ? "النسبة %" : "المبلغ لكل قطعة (ر.س)"}>
            <Input type="number" min={0} step="0.01" value={f.value} onChange={(e) => setF({ ...f, value: e.target.value })} aria-label="قيمة العرض" />
          </Field>
        )}
        <Field label="يُطبق على">
          <Select value={f.scope} onChange={(e) => setF({ ...f, scope: e.target.value as PromoScope })} aria-label="نطاق العرض">
            <option value="all">كل الأصناف</option>
            <option value="category">تصنيف</option>
            <option value="product">منتج (كل مقاساته وألوانه)</option>
          </Select>
        </Field>
        {f.scope === "category" && (
          <Field label="التصنيف">
            <Select value={f.category_id} onChange={(e) => setF({ ...f, category_id: e.target.value })}>
              <option value="">— اختر —</option>
              {categories.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </Select>
          </Field>
        )}
        {f.scope === "product" && (
          <Field label="المنتج">
            <Select value={f.product_id} onChange={(e) => setF({ ...f, product_id: e.target.value })}>
              <option value="">— اختر —</option>
              {products.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </Select>
          </Field>
        )}
        <Field label="أقل عدد قطع لتفعيل العرض">
          <Input type="number" min={1} value={f.min_qty} onChange={(e) => setF({ ...f, min_qty: e.target.value })} />
        </Field>
        <Field label="رمز كوبون (اختياري)" hint="بدون رمز: العرض تلقائي لكل العملاء">
          <Input dir="ltr" className="uppercase" value={f.code} onChange={(e) => setF({ ...f, code: e.target.value.toUpperCase() })} placeholder="SUMMER10" />
        </Field>
        <Field label="يبدأ">
          <Input type="datetime-local" value={f.starts_at} onChange={(e) => setF({ ...f, starts_at: e.target.value })} />
        </Field>
        <Field label="ينتهي" hint="بعده لا يُطبق العرض تلقائياً">
          <Input type="datetime-local" value={f.ends_at} onChange={(e) => setF({ ...f, ends_at: e.target.value })} />
        </Field>
        <Field label="ملاحظات" className="sm:col-span-2">
          <Textarea value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} />
        </Field>
        <Checkbox label="العرض مفعّل" checked={f.is_active} onChange={(v) => setF({ ...f, is_active: v })} />
      </div>
    </Modal>
  );
}
