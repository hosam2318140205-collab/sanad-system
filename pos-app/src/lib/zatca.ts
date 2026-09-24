/**
 * ZATCA (هيئة الزكاة والضريبة والجمارك) simplified tax invoice QR — Phase 1 TLV:
 * 1 seller name, 2 VAT number, 3 timestamp (ISO 8601), 4 total incl. VAT, 5 VAT amount.
 */
function tlv(tag: number, value: string): Uint8Array {
  const bytes = new TextEncoder().encode(value);
  const out = new Uint8Array(2 + bytes.length);
  out[0] = tag;
  out[1] = bytes.length;
  out.set(bytes, 2);
  return out;
}

export function zatcaQrPayload(input: {
  sellerName: string;
  vatNumber: string;
  timestamp: string;
  total: number;
  vat: number;
}): string {
  const parts = [
    tlv(1, input.sellerName),
    tlv(2, input.vatNumber),
    tlv(3, new Date(input.timestamp).toISOString()),
    tlv(4, input.total.toFixed(2)),
    tlv(5, input.vat.toFixed(2)),
  ];
  const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    all.set(p, offset);
    offset += p.length;
  }
  let binary = "";
  all.forEach((b) => (binary += String.fromCharCode(b)));
  return btoa(binary);
}
