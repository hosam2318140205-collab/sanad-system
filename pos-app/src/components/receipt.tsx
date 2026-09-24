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
        </tbody>
      </table>

      {qr && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={qr} alt="ZATCA QR" style={{ width: "34mm", height: "34mm", margin: "8px auto 4px", display: "block" }} />
      )}
      {settings.receipt_footer && (
        <div style={{ textAlign: "center", marginTop: 4, whiteSpace: "pre-line" }}>{settings.receipt_footer}</div>
      )}
      <div style={{ textAlign: "center", marginTop: 4, fontSize: "0.85em" }}>المبالغ بالريال السعودي — {money(sale.total)}</div>
    </div>
  );
}
