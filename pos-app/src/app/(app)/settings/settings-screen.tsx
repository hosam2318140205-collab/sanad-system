"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { useSession } from "@/components/session-context";
import { Button, Card, Checkbox, Field, Input, PageHeader, Textarea, useToast } from "@/components/ui";
import { errorMessage } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { StoreSettings } from "@/lib/types";

export function SettingsScreen() {
  const { settings } = useSession();
  const toast = useToast();
  const router = useRouter();
  const [s, setS] = useState<StoreSettings>(settings);
  const [busy, setBusy] = useState(false);

  const set = <K extends keyof StoreSettings>(k: K, v: StoreSettings[K]) => setS((p) => ({ ...p, [k]: v }));
  const text = (k: keyof StoreSettings) => ({
    value: (s[k] as string | null) ?? "",
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => set(k, (e.target.value || null) as never),
  });

  const vatValid = !s.vat_number || /^3\d{13}3$/.test(s.vat_number);

  const save = async () => {
    if (!s.store_name.trim()) return toast("اسم المتجر مطلوب", "error");
    setBusy(true);
    const { error } = await supabase()
      .from("store_settings")
      .update({
        store_name: s.store_name.trim(),
        store_name_en: s.store_name_en,
        vat_number: s.vat_number,
        cr_number: s.cr_number,
        phone: s.phone,
        address: s.address,
        logo_url: s.logo_url,
        receipt_footer: s.receipt_footer,
        vat_rate: Number(s.vat_rate),
        prices_include_vat: s.prices_include_vat,
        allow_negative_stock: s.allow_negative_stock,
        allow_cashier_returns: s.allow_cashier_returns,
        require_shift: s.require_shift,
        inventory_segregation: !!s.inventory_segregation,
        purchase_match_tolerance_pct: Number(s.purchase_match_tolerance_pct ?? 2),
        supplier_weight_price: Number(s.supplier_weight_price ?? 50),
        supplier_weight_lead: Number(s.supplier_weight_lead ?? 20),
        supplier_weight_fill: Number(s.supplier_weight_fill ?? 15),
        supplier_weight_quality: Number(s.supplier_weight_quality ?? 15),
        max_cashier_discount_pct: Number(s.max_cashier_discount_pct),
        return_days: Number(s.return_days),
      })
      .eq("id", 1);
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    toast("تم حفظ الإعدادات");
    router.refresh();
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="الإعدادات"
        actions={
          <Button onClick={save} loading={busy}>
            حفظ
          </Button>
        }
      />
      <div className="grid gap-4 lg:grid-cols-2">
        <Card className="space-y-3 p-4">
          <h2 className="font-semibold">بيانات المتجر (تظهر في الفاتورة)</h2>
          <Field label="اسم المتجر *">
            <Input {...text("store_name")} />
          </Field>
          <Field label="الاسم بالإنجليزية">
            <Input dir="ltr" {...text("store_name_en")} />
          </Field>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="الرقم الضريبي" hint={vatValid ? "15 رقماً يبدأ وينتهي بـ 3" : "صيغة الرقم الضريبي غير صحيحة"}>
              <Input dir="ltr" {...text("vat_number")} className={vatValid ? "" : "border-red-500"} />
            </Field>
            <Field label="السجل التجاري">
              <Input dir="ltr" {...text("cr_number")} />
            </Field>
            <Field label="الهاتف">
              <Input dir="ltr" {...text("phone")} />
            </Field>
            <Field label="رابط الشعار">
              <Input dir="ltr" {...text("logo_url")} placeholder="https://..." />
            </Field>
          </div>
          <Field label="العنوان">
            <Input {...text("address")} />
          </Field>
          <Field label="تذييل الفاتورة">
            <Textarea {...text("receipt_footer")} />
          </Field>
        </Card>

        <Card className="space-y-3 p-4">
          <h2 className="font-semibold">الضريبة والبيع</h2>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="نسبة ضريبة القيمة المضافة %">
              <Input type="number" step="0.01" value={s.vat_rate} onChange={(e) => set("vat_rate", Number(e.target.value))} />
            </Field>
            <Field label="أقصى خصم للكاشير %">
              <Input type="number" step="0.5" value={s.max_cashier_discount_pct} onChange={(e) => set("max_cashier_discount_pct", Number(e.target.value))} />
            </Field>
            <Field label="مدة الإرجاع (أيام)">
              <Input type="number" value={s.return_days} onChange={(e) => set("return_days", Number(e.target.value))} />
            </Field>
          </div>
          <Checkbox label="أسعار البيع شاملة الضريبة (المعتاد في التجزئة)" checked={s.prices_include_vat} onChange={(v) => set("prices_include_vat", v)} />
          <Checkbox label="السماح بالبيع عند نفاد المخزون (مخزون سالب)" checked={s.allow_negative_stock} onChange={(v) => set("allow_negative_stock", v)} />
          <Checkbox label="السماح للكاشير بالإرجاع والاستبدال" checked={s.allow_cashier_returns} onChange={(v) => set("allow_cashier_returns", v)} />
          <Checkbox label="البيع والإرجاع النقدي يتطلبان وردية مفتوحة" checked={s.require_shift} onChange={(v) => set("require_shift", v)} />
          <Checkbox
            label="فصل المهام في المخزون: من يطلب التحويل لا يعتمده، ومن سجّل فرق الاستلام لا يعتمد فقده"
            checked={!!s.inventory_segregation}
            onChange={(v) => set("inventory_segregation", v)}
          />
          <div className="rounded-lg border border-slate-200 p-3">
            <p className="mb-2 text-sm font-medium text-slate-800">المشتريات والموردون</p>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
              <Field label="سماح فرق السعر في المطابقة %">
                <Input type="number" min={0} max={50} step="0.5" value={s.purchase_match_tolerance_pct ?? 2}
                  onChange={(e) => set("purchase_match_tolerance_pct", Number(e.target.value))} />
              </Field>
              <Field label="وزن التكلفة %">
                <Input type="number" min={0} max={100} value={s.supplier_weight_price ?? 50} onChange={(e) => set("supplier_weight_price", Number(e.target.value))} />
              </Field>
              <Field label="وزن مدة التوريد %">
                <Input type="number" min={0} max={100} value={s.supplier_weight_lead ?? 20} onChange={(e) => set("supplier_weight_lead", Number(e.target.value))} />
              </Field>
              <Field label="وزن نسبة التوريد %">
                <Input type="number" min={0} max={100} value={s.supplier_weight_fill ?? 15} onChange={(e) => set("supplier_weight_fill", Number(e.target.value))} />
              </Field>
              <Field label="وزن الجودة %">
                <Input type="number" min={0} max={100} value={s.supplier_weight_quality ?? 15} onChange={(e) => set("supplier_weight_quality", Number(e.target.value))} />
              </Field>
            </div>
            <p className="mt-2 text-xs text-slate-500">
              أوزان اقتراح المورد مجموعها 100 (الحالي: {Number(s.supplier_weight_price ?? 50) + Number(s.supplier_weight_lead ?? 20) + Number(s.supplier_weight_fill ?? 15) + Number(s.supplier_weight_quality ?? 15)}).
            </p>
          </div>
          <p className="rounded-lg bg-amber-50 p-3 text-xs text-amber-800">
            تغيير نسبة الضريبة أو طريقة التسعير يؤثر على الفواتير الجديدة فقط. الفواتير السابقة تحتفظ بنسبتها.
          </p>
        </Card>
      </div>
    </div>
  );
}
