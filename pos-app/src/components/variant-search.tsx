"use client";

import { ScanBarcode } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { fetchCatalog, normalize } from "@/lib/catalog";
import { money, variantLabel } from "@/lib/format";
import type { CatalogItem } from "@/lib/types";
import { CameraScanButton, CameraScanner } from "./camera-scanner";
import { Input } from "./ui";

/** Search/scan any sellable variant. Enter with an exact barcode/SKU picks immediately. */
export function VariantSearch({ onPick, placeholder }: { onPick: (item: CatalogItem) => void; placeholder?: string }) {
  const [catalog, setCatalog] = useState<CatalogItem[]>([]);
  const [q, setQ] = useState("");
  const [open, setOpen] = useState(false);
  const [camera, setCamera] = useState(false);

  useEffect(() => {
    fetchCatalog()
      .then(setCatalog)
      .catch(() => setCatalog([]));
  }, []);

  const results = useMemo(() => {
    const term = normalize(q);
    if (!term) return [];
    return catalog
      .filter(
        (c) =>
          normalize(`${c.product_name} ${c.size ?? ""} ${c.color ?? ""}`).includes(term) ||
          c.sku.toLowerCase().includes(term) ||
          c.barcode?.includes(term),
      )
      .slice(0, 12);
  }, [catalog, q]);

  const pick = (item: CatalogItem) => {
    onPick(item);
    setQ("");
    setOpen(false);
  };

  return (
    <div className="flex gap-2">
      <div className="relative min-w-0 flex-1">
        <ScanBarcode className="pointer-events-none absolute start-3 top-1/2 size-5 -translate-y-1/2 text-slate-400" />
        <Input
          className="h-11 ps-10"
          placeholder={placeholder ?? "امسح الباركود أو ابحث عن صنف"}
          value={q}
          onChange={(e) => {
            setQ(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
          onKeyDown={(e) => {
            if (e.key !== "Enter") return;
            e.preventDefault();
            const code = q.trim();
            const exact = catalog.find((c) => c.barcode === code || c.sku.toLowerCase() === code.toLowerCase());
            if (exact) pick(exact);
            else if (results.length === 1) pick(results[0]);
          }}
        />
        {open && results.length > 0 && (
          <ul className="absolute inset-x-0 top-full z-20 mt-1 max-h-80 overflow-y-auto rounded-lg border border-slate-200 bg-white shadow-lg">
            {results.map((r) => (
              <li key={r.variant_id}>
                <button
                  type="button"
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => pick(r)}
                  className="flex w-full items-center justify-between gap-2 px-3 py-2 text-start text-sm hover:bg-slate-50"
                >
                  <span>
                    <span className="font-medium">{r.product_name}</span>{" "}
                    <span className="text-slate-500">{variantLabel(r.size, r.color)}</span>
                  </span>
                  <span className="text-xs text-slate-500">
                    مخزون {r.stock_qty} · {money(r.price)}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
      <CameraScanButton size="lg" className="h-11" onClick={() => setCamera(true)} />
      <CameraScanner
        open={camera}
        onClose={() => setCamera(false)}
        onDetected={(code) => {
          const item = catalog.find((c) => c.barcode === code || c.sku.toLowerCase() === code.toLowerCase());
          if (!item) return { ok: false, message: `لا يوجد صنف بالرمز ${code}` };
          pick(item);
          return { ok: true, message: item.product_name };
        }}
      />
    </div>
  );
}
