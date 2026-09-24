"use client";

import JsBarcode from "jsbarcode";
import { useEffect, useRef } from "react";

export interface LabelItem {
  key: string;
  name: string;
  variant: string;
  price: number;
  code: string;
  copies: number;
}

function BarcodeSvg({ code }: { code: string }) {
  const ref = useRef<SVGSVGElement>(null);
  useEffect(() => {
    if (!ref.current) return;
    try {
      JsBarcode(ref.current, code, {
        format: /^\d{13}$/.test(code) ? "EAN13" : "CODE128",
        width: 1.4,
        height: 34,
        fontSize: 11,
        margin: 0,
        // EAN-13 prints its first digit to the left of the bars; leave room so it isn't clipped
        marginLeft: 10,
        displayValue: true,
      });
    } catch {
      JsBarcode(ref.current, code, { format: "CODE128", width: 1.2, height: 34, fontSize: 11, margin: 0 });
    }
  }, [code]);
  return <svg ref={ref} style={{ maxWidth: "100%" }} />;
}

/** ملصقات باركود 50×30mm (طابعات الملصقات الحرارية) */
export function BarcodeLabels({ items, storeName }: { items: LabelItem[]; storeName: string }) {
  const labels = items.flatMap((i) => Array.from({ length: Math.max(0, i.copies) }, (_, n) => ({ ...i, n })));
  return (
    <div dir="rtl">
      {labels.map((l) => (
        <div
          key={`${l.key}-${l.n}`}
          style={{
            width: "50mm",
            height: "30mm",
            padding: "1.5mm",
            boxSizing: "border-box",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "space-between",
            pageBreakAfter: "always",
            fontSize: 9,
            color: "#000",
            overflow: "hidden",
          }}
        >
          <div style={{ fontWeight: 700, whiteSpace: "nowrap", overflow: "hidden", maxWidth: "100%" }}>
            {storeName} — {l.name}
          </div>
          <BarcodeSvg code={l.code} />
          <div style={{ display: "flex", justifyContent: "space-between", width: "100%", fontWeight: 700 }}>
            <span>{l.variant}</span>
            <span>{l.price.toFixed(2)} ر.س</span>
          </div>
        </div>
      ))}
    </div>
  );
}
