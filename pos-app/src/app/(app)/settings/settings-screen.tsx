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
        max_cashier_discount_pct: Number(s.max_cashier_discount_pct),
        return_days: Number(s.return_days),
        loyalty_enabled: s.loyalty_enabled,
        loyalty_points_per_sar: Number(s.loyalty_points_per_sar),
        loyalty_point_value: Number(s.loyalty_point_value),
        loyalty_min_redeem: Number(s.loyalty_min_redeem),
        loyalty_max_redeem_pct: Number(s.loyalty_max_redeem_pct),
        allow_cashier_credit: s.allow_cashier_credit,
        reservation_days: Number(s.reservation_days),
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
          <p className="rounded-lg bg-amber-50 p-3 text-xs text-amber-800">
            تغيير نسبة الضريبة أو طريقة التسعير يؤثر على الفواتير الجديدة فقط. الفواتير السابقة تحتفظ بنسبتها.
          </p>
        </Card>

        <Card className="space-y-3 p-4 lg:col-span-2" >
          <h2 className="font-semibold">العملاء: نقاط الولاء، البيع الآجل، الحجز</h2>
          <Checkbox label="تفعيل برنامج نقاط الولاء" checked={s.loyalty_enabled} onChange={(v) => set("loyalty_enabled", v)} />
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Field label="نقاط لكل 1 ر.س مدفوع" hint={`كل ${Number(s.loyalty_points_per_sar) > 0 ? (1 / Number(s.loyalty_points_per_sar)).toFixed(0) : "—"} ر.س = نقطة`}>
              <Input type="number" step="0.01" min={0} value={s.loyalty_points_per_sar} onChange={(e) => set("loyalty_points_per_sar", Number(e.target.value))} />
            </Field>
            <Field label="قيمة النقطة (ر.س)" hint={`100 نقطة = ${(Number(s.loyalty_point_value) * 100).toFixed(2)} ر.س`}>
              <Input type="number" step="0.01" min={0} value={s.loyalty_point_value} onChange={(e) => set("loyalty_point_value", Number(e.target.value))} />
            </Field>
            <Field label="أقل عدد نقاط للاستبدال">
              <Input type="number" min={1} value={s.loyalty_min_redeem} onChange={(e) => set("loyalty_min_redeem", Number(e.target.value))} />
            </Field>
            <Field label="أقصى نسبة من الفاتورة بالنقاط %">
              <Input type="number" min={1} max={100} value={s.loyalty_max_redeem_pct} onChange={(e) => set("loyalty_max_redeem_pct", Number(e.target.value))} />
            </Field>
          </div>
          <p className="text-xs text-slate-500">
            العائد للعميل = {(Number(s.loyalty_points_per_sar) * Number(s.loyalty_point_value) * 100).toFixed(2)}% من المدفوع. استبدال النقاط يُعامل كخصم
            تُحسب الضريبة بعده، ولا تُكسب نقاط على الجزء الآجل أو رصيد الاستبدال.
          </p>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Field label="مدة الحجز الافتراضية (أيام)">
              <Input type="number" min={1} max={60} value={s.reservation_days} onChange={(e) => set("reservation_days", Number(e.target.value))} />
            </Field>
          </div>
          <Checkbox
            label="السماح للكاشير بالبيع الآجل (ضمن حد ائتمان العميل الذي يحدده المدير)"
            checked={s.allow_cashier_credit}
            onChange={(v) => set("allow_cashier_credit", v)}
          />
        </Card>
      </div>
    </div>
  );
}
