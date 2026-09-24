import { round2 } from "./format";

export interface PricedLine {
  price: number;
  qty: number;
  discount: number;
}

export interface CartTotals {
  gross: number;
  lineDiscounts: number;
  invoiceDiscount: number;
  discountTotal: number;
  subtotal: number; // excl. VAT, after discounts
  vat: number;
  total: number; // incl. VAT
  lines: { lineTotal: number; vat: number }[];
}

/**
 * Mirrors public.complete_sale() so the screen shows exactly what the server will store.
 * The server recomputes everything from catalog prices; this is display only.
 */
export function computeTotals(
  lines: PricedLine[],
  invoiceDiscountInput: number,
  vatRate: number,
  pricesIncludeVat: boolean,
): CartTotals {
  const prepared = lines.map((l) => {
    const gross = round2(l.price * l.qty);
    const disc = round2(Math.min(Math.max(l.discount || 0, 0), gross));
    return { gross, disc };
  });
  const gross = round2(prepared.reduce((s, l) => s + l.gross, 0));
  const lineDiscounts = round2(prepared.reduce((s, l) => s + l.disc, 0));
  const base = round2(gross - lineDiscounts);
  const invoiceDiscount = round2(Math.min(Math.max(invoiceDiscountInput || 0, 0), base));

  let allocated = 0;
  let total = 0;
  let vat = 0;
  const out = prepared.map((l, idx) => {
    let net = l.gross - l.disc;
    let alloc: number;
    if (idx === prepared.length - 1) alloc = round2(invoiceDiscount - allocated);
    else alloc = base > 0 ? round2((invoiceDiscount * net) / base) : 0;
    allocated = round2(allocated + alloc);
    net = net - alloc;

    let lineTotal: number;
    let lineVat: number;
    if (pricesIncludeVat) {
      lineTotal = round2(net);
      lineVat = round2((net * vatRate) / (100 + vatRate));
    } else {
      lineVat = round2((net * vatRate) / 100);
      lineTotal = round2(net) + lineVat;
    }
    total = round2(total + lineTotal);
    vat = round2(vat + lineVat);
    return { lineTotal, vat: lineVat };
  });

  return {
    gross,
    lineDiscounts,
    invoiceDiscount,
    discountTotal: round2(lineDiscounts + invoiceDiscount),
    subtotal: round2(total - vat),
    vat,
    total,
    lines: out,
  };
}
