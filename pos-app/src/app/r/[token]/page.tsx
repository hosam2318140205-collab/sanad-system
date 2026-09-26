import type { Metadata } from "next";
import { notFound } from "next/navigation";
import QRCode from "qrcode";
import { PAYMENT_LABELS, dateTime } from "@/lib/format";
import { createServerSupabase } from "@/lib/supabase/server";
import type { PaymentMethod } from "@/lib/types";
import { zatcaQrPayload } from "@/lib/zatca";

export const metadata: Metadata = {
  title: "فاتورة",
  robots: { index: false, follow: false },
};

interface PublicReceipt {
  store: {
    name: string;
    name_en: string | null;
    vat_number: string | null;
    cr_number: string | null;
    phone: string | null;
    address: string | null;
    footer: string | null;
  };
  invoice_no: string;
  created_at: string;
  status: "completed" | "partially_returned" | "returned";
  subtotal: number;
  discount_total: number;
  vat_rate: number;
  vat_amount: number;
  total: number;
  change_amount: number;
  returned_amount: number;
  loyalty_points_earned: number;
  items: Array<{
    product_name: string;
    variant_label: string | null;
    qty: number;
    unit_price: number;
    line_discount: number;
    line_total: number;
    returned_qty: number;
  }>;
  payments: Array<{ method: PaymentMethod; amount: number }>;
}

const f = (n: number) => Number(n).toFixed(2);

export default async function PublicReceiptPage({ params }: PageProps<"/r/[token]">) {
  const { token } = await params;
  if (!/^[0-9a-f]{32}$/.test(token)) notFound();
  const supabase = await createServerSupabase();
  const { data } = await supabase.rpc("public_receipt", { p_token: token });
  const r = data as PublicReceipt | null;
  if (!r) notFound();

  const qr = await QRCode.toDataURL(
    zatcaQrPayload({
      sellerName: r.store.name,
      vatNumber: r.store.vat_number ?? "",
      timestamp: r.created_at,
      total: Number(r.total),
      vat: Number(r.vat_amount),
    }),
    { margin: 0, width: 220, errorCorrectionLevel: "M" },
  );

  return (
    <main className="min-h-dvh bg-slate-100 px-4 py-6">
      <article className="mx-auto max-w-md rounded-2xl bg-white p-5 shadow-sm" data-testid="public-receipt">
        <header className="text-center">
          <h1 className="text-xl font-bold">{r.store.name}</h1>
          {r.store.name_en && <p className="text-sm text-slate-500">{r.store.name_en}</p>}
          {r.store.address && <p className="text-sm text-slate-500">{r.store.address}</p>}
          {r.store.vat_number && <p className="text-sm">الرقم الضريبي: {r.store.vat_number}</p>}
          <p className="mt-2 font-semibold">فاتورة ضريبية مبسطة</p>
        </header>

        <dl className="mt-4 grid grid-cols-2 gap-y-1 border-y border-dashed border-slate-300 py-3 text-sm">
          <dt className="text-slate-500">رقم الفاتورة</dt>
          <dd className="text-left font-medium" dir="ltr">
            {r.invoice_no}
          </dd>
          <dt className="text-slate-500">التاريخ</dt>
          <dd className="text-left" dir="ltr">
            {dateTime(r.created_at)}
          </dd>
          {r.status !== "completed" && (
            <>
              <dt className="text-slate-500">الحالة</dt>
              <dd className="text-left text-red-600">{r.status === "returned" ? "مرتجعة" : `مرتجع جزئي (${f(r.returned_amount)})`}</dd>
            </>
          )}
        </dl>

        <ul className="divide-y divide-slate-100 text-sm">
          {r.items.map((i, idx) => (
            <li key={idx} className="flex items-start justify-between gap-3 py-2">
              <div className="min-w-0">
                <p className="font-medium">{i.product_name}</p>
                <p className="text-xs text-slate-500">
                  {i.variant_label ? `${i.variant_label} · ` : ""}
                  {i.qty} × {f(i.unit_price)}
                  {Number(i.line_discount) > 0 && ` · خصم ${f(i.line_discount)}`}
                  {i.returned_qty > 0 && ` · مرتجع ${i.returned_qty}`}
                </p>
              </div>
              <p className="shrink-0 font-semibold">{f(i.line_total)}</p>
            </li>
          ))}
        </ul>

        <dl className="mt-2 space-y-1 border-t border-dashed border-slate-300 pt-3 text-sm">
          {Number(r.discount_total) > 0 && (
            <div className="flex justify-between">
              <dt>إجمالي الخصم</dt>
              <dd>{f(r.discount_total)}</dd>
            </div>
          )}
          <div className="flex justify-between">
            <dt>الإجمالي غير شامل الضريبة</dt>
            <dd>{f(r.subtotal)}</dd>
          </div>
          <div className="flex justify-between">
            <dt>ضريبة القيمة المضافة {Number(r.vat_rate)}%</dt>
            <dd>{f(r.vat_amount)}</dd>
          </div>
          <div className="flex justify-between text-lg font-bold">
            <dt>الإجمالي شامل الضريبة</dt>
            <dd data-testid="public-total">{f(r.total)} ر.س</dd>
          </div>
          {r.payments.map((p, idx) => (
            <div key={idx} className="flex justify-between text-slate-600">
              <dt>{PAYMENT_LABELS[p.method] ?? p.method}</dt>
              <dd>{f(p.amount)}</dd>
            </div>
          ))}
          {Number(r.loyalty_points_earned) > 0 && (
            <div className="flex justify-between text-amber-700">
              <dt>نقاط مكتسبة</dt>
              <dd>{r.loyalty_points_earned}</dd>
            </div>
          )}
        </dl>

        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={qr} alt="رمز هيئة الزكاة" className="mx-auto mt-4 size-36" />
        {r.store.footer && <p className="mt-3 whitespace-pre-line text-center text-xs text-slate-500">{r.store.footer}</p>}
        <p className="mt-3 text-center text-xs text-slate-400">للإرجاع أو الاستبدال اعرض هذه الصفحة في المتجر</p>
      </article>
    </main>
  );
}
