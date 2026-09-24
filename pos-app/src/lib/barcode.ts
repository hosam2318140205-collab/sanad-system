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
  const body = `20${Date.now().toString().slice(-7)}${Math.floor(Math.random() * 1000)
    .toString()
    .padStart(3, "0")}`;
  return body + ean13CheckDigit(body);
}

export function isValidEan13(code: string): boolean {
  return /^\d{13}$/.test(code) && ean13CheckDigit(code.slice(0, 12)) === Number(code[12]);
}

export function makeSku(productName: string, size: string | null, color: string | null, seq: number): string {
  const base = productName
    .replace(/[^A-Za-z0-9]/g, "")
    .slice(0, 4)
    .toUpperCase();
  const prefix = base || "P" + Date.now().toString(36).slice(-4).toUpperCase();
  const parts = [prefix, size?.replace(/\s+/g, ""), color ? String(seq).padStart(2, "0") : null].filter(Boolean);
  return parts.join("-");
}
