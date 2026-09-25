/** EAN-13 check digit for the first 12 digits. */
export function ean13CheckDigit(first12: string): number {
  let sum = 0;
  for (let i = 0; i < 12; i++) {
    const d = Number(first12[i]);
    sum += i % 2 === 0 ? d : d * 3;
  }
  return (10 - (sum % 10)) % 10;
}

/** Internal store barcode (prefix 20–29 is reserved for in-store use). */
export function generateEan13(): string {
  return generateEan13Batch(1)[0];
}

/**
 * `count` distinct internal EAN-13 codes in one go (e.g. 7 sizes × 7 colors = 49),
 * none of which appear in `taken`. Codes share a time-based stem and a running counter,
 * so a batch can never contain duplicates (random suffixes collided within one batch).
 */
export function generateEan13Batch(count: number, taken: Iterable<string> = []): string[] {
  const used = new Set(taken);
  const stem = `20${Date.now().toString().slice(-7)}`; // 9 digits
  let counter = Math.floor(Math.random() * 1000);
  const out: string[] = [];
  for (let guard = 0; out.length < count && guard < 1000; guard++) {
    const body = stem + String(counter % 1000).padStart(3, "0");
    counter++;
    const code = body + ean13CheckDigit(body);
    if (used.has(code)) continue;
    used.add(code);
    out.push(code);
  }
  return out;
}

export function isValidEan13(code: string): boolean {
  return /^\d{13}$/.test(code) && ean13CheckDigit(code.slice(0, 12)) === Number(code[12]);
}

/**
 * SKU like SHOE-K3F9-42-03: name letters (when Latin), a short code unique to this
 * generation batch (so similarly named products don't collide), size, and a color index.
 */
export function makeSku(productName: string, size: string | null, color: string | null, seq: number, batch: string): string {
  const base = productName
    .replace(/[^A-Za-z0-9]/g, "")
    .slice(0, 4)
    .toUpperCase();
  const parts = [base || "P", batch, size?.replace(/\s+/g, ""), color ? String(seq).padStart(2, "0") : null].filter(Boolean);
  return parts.join("-");
}

/** Short code for one generation batch (base36 time, 4 chars). */
export function skuBatchCode(): string {
  return Date.now().toString(36).slice(-4).toUpperCase();
}
