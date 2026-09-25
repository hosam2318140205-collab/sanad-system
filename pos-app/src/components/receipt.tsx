"use client";

import QRCode from "qrcode";
import { useEffect, useState } from "react";
import { PAYMENT_LABELS, dateTime, money } from "@/lib/format";
import type { Sale, SaleItem, SalePayment, StoreSettings } from "@/lib/types";
import { zatcaQrPayload } from "@/lib/zatca";

export interface ReceiptData {
  sale: Sale;
  items: SaleItem[];
  payments: SalePayment[];
  cashierName?: string | null;
  customerName?: string | null;
  customerVat?: string | null;
  customerPhone?: string | null;
  customerId?: string | null;
  /** رصيد العميل بعد الفاتورة (النقاط والذمة) */
  customerPoints?: number | null;
  customerBalance?: number | null;
}

const fmt = (n: number) => Number(n).toFixed(2);

/** فاتورة ضريبية مبسطة بعرض 80mm للطابعات الحرارية */
export function Receipt({
  data,
  settings,
  width = "80",
  copyLabel,
}: {
  data: ReceiptData;
  settings: StoreSettings;
  width?: "80" | "58";
  copyLabel?: string;
}) {
  const { sale, items, payments } = data;
  const [qr, setQr] = useState<string | null>(null);
  const [lookupQr, setLookupQr] = useState<string | null>(null);
  const token = sale.public_token;

  // QR ثانٍ: رابط الفاتورة — العميل يعرضها من جواله، والكاشير يمسحه لاسترجاع الفاتورة في المرتجع/الاستبدال
  useEffect(() => {
    let cancelled = false;
    if (!token) return;
    QRCode.toDataURL(`${window.location.origin}/r/${token}`, { margin: 0, width: 200, errorCorrectionLevel: "M" })
      .then((url) => !cancelled && setLookupQr(url))
      .catch(() => !cancelled && setLookupQr(null));
    return () => {
      cancelled = true;
    };
  }, [token]);

  useEffect(() => {
    let cancelled = false;
    const payload = zatcaQrPayload({
      sellerName: settings.store_name,
      vatNumber: settings.vat_number ?? "",
      timestamp: sale.created_at,
      total: Number(sale.total),
      vat: Number(sale.vat_amount),
    });
    QRCode.toDataURL(payload, { margin: 0, width: 220, errorCorrectionLevel: "M" })
      .then((url) => !cancelled && setQr(url))
      .catch(() => !cancelled && setQr(null));
    return () => {
      cancelled = true;
    };
  }, [sale.created_at, sale.total, sale.vat_amount, settings.store_name, settings.vat_number]);

  return (
    <div className={`receipt ${width === "58" ? "w58" : ""}`} dir="rtl">
      <div style={{ textAlign: "center" }}>
        {settings.logo_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={settings.logo_url} alt="" style={{ maxHeight: 50, margin: "0 auto 4px" }} />
        )}
        <div style={{ fontSize: "1.35em", fontWeight: 700 }}>{settings.store_name}</div>
        {settings.store_name_en && <div>{settings.store_name_en}</div>}
        {settings.address && <div>{settings.address}</div>}
        {settings.phone && <div className="ltr-nums">{settings.phone}</div>}
        {settings.vat_number && <div>الرقم الضريبي: {settings.vat_number}</div>}
        {settings.cr_number && <div>السجل التجاري: {settings.cr_number}</div>}
        <div style={{ fontWeight: 700, marginTop: 4 }}>فاتورة ضريبية مبسطة</div>
        <div>Simplified Tax Invoice</div>
        {copyLabel && <div style={{ fontWeight: 700 }}>{copyLabel}</div>}
      </div>

      <div className="dashed" />
      <table>
        <tbody>
          <tr>
            <td>رقم الفاتورة</td>
            <td style={{ textAlign: "left" }}>{sale.invoice_no}</td>
          </tr>
          <tr>
            <td>التاريخ</td>
            <td style={{ textAlign: "left" }} className="ltr-nums">
              {dateTime(sale.created_at)}
            </td>
          </tr>
          {data.cashierName && (
            <tr>
              <td>الكاشير</td>
              <td style={{ textAlign: "left" }}>{data.cashierName}</td>
            </tr>
          )}
          {data.customerName && (
            <tr>
              <td>العميل</td>
              <td style={{ textAlign: "left" }}>{data.customerName}</td>
            </tr>
          )}
          {data.customerVat && (
            <tr>
              <td>ضريبي العميل</td>
              <td style={{ textAlign: "left" }}>{data.customerVat}</td>
            </tr>
          )}
        </tbody>
      </table>
      <div className="dashed" />

      <table>
        <thead>
          <tr style={{ borderBottom: "1px solid #000" }}>
            <th style={{ textAlign: "right" }}>الصنف</th>
            <th>كمية</th>
            <th>سعر</th>
            <th style={{ textAlign: "left" }}>المجموع</th>
          </tr>
        </thead>
        <tbody>
          {items.map((i) => (
            <tr key={i.id} style={{ verticalAlign: "top" }}>
              <td style={{ paddingTop: 3 }}>
                {i.product_name}
                {i.variant_label && <div style={{ fontSize: "0.9em" }}>{i.variant_label}</div>}
                {Number(i.line_discount) > 0 && <div style={{ fontSize: "0.9em" }}>خصم: {fmt(i.line_discount)}</div>}
              </td>
              <td style={{ textAlign: "center" }}>{i.qty}</td>
              <td style={{ textAlign: "center" }}>{fmt(i.unit_price)}</td>
              <td style={{ textAlign: "left" }}>{fmt(i.line_total)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="dashed" />

      <table>
        <tbody>
          {Number(sale.discount_total) > 0 && (
            <tr>
              <td>إجمالي الخصم</td>
              <td style={{ textAlign: "left" }}>{fmt(sale.discount_total)}</td>
            </tr>
          )}
          {Number(sale.promo_discount ?? 0) > 0 && (
            <tr style={{ fontSize: "0.9em" }}>
              <td>منها عروض{sale.promo_code ? ` (${sale.promo_code})` : ""}</td>
              <td style={{ textAlign: "left" }}>{fmt(sale.promo_discount ?? 0)}</td>
            </tr>
          )}
          {Number(sale.loyalty_points_redeemed ?? 0) > 0 && (
            <tr style={{ fontSize: "0.9em" }}>
              <td>منها استبدال {sale.loyalty_points_redeemed} نقطة</td>
              <td style={{ textAlign: "left" }}>{fmt(sale.loyalty_discount ?? 0)}</td>
            </tr>
          )}
          <tr>
            <td>الإجمالي غير شامل الضريبة</td>
            <td style={{ textAlign: "left" }}>{fmt(sale.subtotal)}</td>
          </tr>
          <tr>
            <td>ضريبة القيمة المضافة {Number(sale.vat_rate)}%</td>
            <td style={{ textAlign: "left" }}>{fmt(sale.vat_amount)}</td>
          </tr>
          <tr style={{ fontSize: "1.25em", fontWeight: 700 }}>
            <td>الإجمالي شامل الضريبة</td>
            <td style={{ textAlign: "left" }}>{fmt(sale.total)}</td>
          </tr>
        </tbody>
      </table>
      <div className="dashed" />

      <table>
        <tbody>
          {payments.map((p) => (
            <tr key={p.id}>
              <td>{PAYMENT_LABELS[p.method]}</td>
              <td style={{ textAlign: "left" }}>{fmt(p.amount)}</td>
            </tr>
          ))}
          {Number(sale.change_amount) > 0 && (
            <tr>
              <td>الباقي للعميل</td>
              <td style={{ textAlign: "left" }}>{fmt(sale.change_amount)}</td>
            </tr>
          )}
          {data.customerBalance != null && payments.some((p) => p.method === "on_account") && (
            <tr>
              <td>رصيد حساب العميل</td>
              <td style={{ textAlign: "left" }}>{fmt(data.customerBalance)}</td>
            </tr>
          )}
        </tbody>
      </table>
      {(Number(sale.loyalty_points_earned ?? 0) > 0 || data.customerPoints != null) && data.customerName && (
        <>
          <div className="dashed" />
          <table>
            <tbody>
              {Number(sale.loyalty_points_earned ?? 0) > 0 && (
                <tr>
                  <td>نقاط مكتسبة</td>
                  <td style={{ textAlign: "left" }}>{sale.loyalty_points_earned}</td>
                </tr>
              )}
              {data.customerPoints != null && (
                <tr>
                  <td>رصيد النقاط</td>
                  <td style={{ textAlign: "left" }}>{data.customerPoints}</td>
                </tr>
              )}
            </tbody>
          </table>
        </>
      )}

      <div style={{ display: "flex", justifyContent: "center", alignItems: "flex-start", gap: "4mm", marginTop: 8 }}>
        {qr && (
          <div style={{ textAlign: "center" }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={qr} alt="ZATCA QR" style={{ width: "30mm", height: "30mm", display: "block" }} />
            <div style={{ fontSize: "0.75em" }}>هيئة الزكاة</div>
          </div>
        )}
        {lookupQr && (
          <div style={{ textAlign: "center" }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={lookupQr} alt="رمز الفاتورة" data-testid="lookup-qr" style={{ width: "22mm", height: "22mm", display: "block" }} />
            <div style={{ fontSize: "0.75em" }}>الفاتورة / الإرجاع</div>
          </div>
        )}
      </div>
      {settings.receipt_footer && (
        <div style={{ textAlign: "center", marginTop: 4, whiteSpace: "pre-line" }}>{settings.receipt_footer}</div>
      )}
      <div style={{ textAlign: "center", marginTop: 4, fontSize: "0.85em" }}>المبالغ بالريال السعودي — {money(sale.total)}</div>
    </div>
  );
}
