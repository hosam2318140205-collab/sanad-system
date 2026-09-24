"use client";

import { useState } from "react";

export interface BarDatum {
  label: string;
  value: number;
  hint?: string;
}

/** Single-series column chart with hover tooltip. Values are formatted by the caller. */
export function ColumnChart({
  data,
  format,
  height = 200,
}: {
  data: BarDatum[];
  format: (n: number) => string;
  height?: number;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const max = Math.max(...data.map((d) => d.value), 0) || 1;
  const labelEvery = Math.ceil(data.length / 8);

  return (
    <div className="relative" dir="ltr">
      <div className="flex items-end gap-[2px] border-b border-slate-200" style={{ height }}>
        {data.map((d, i) => {
          const h = Math.max((Math.max(d.value, 0) / max) * (height - 8), d.value > 0 ? 2 : 0);
          return (
            <div
              key={i}
              className="group relative flex h-full flex-1 items-end justify-center"
              onMouseEnter={() => setHover(i)}
              onMouseLeave={() => setHover(null)}
              onTouchStart={() => setHover(i)}
            >
              <div
                className={`w-full max-w-9 rounded-t-[4px] transition-colors ${hover === i ? "bg-brand-800" : "bg-brand-600"}`}
                style={{ height: h }}
              />
              {hover === i && (
                <div className="pointer-events-none absolute bottom-full z-10 mb-1 whitespace-nowrap rounded-md bg-slate-900 px-2 py-1 text-center text-xs text-white shadow">
                  <div className="font-semibold">{format(d.value)}</div>
                  <div className="text-slate-300">
                    {d.label}
                    {d.hint ? ` · ${d.hint}` : ""}
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
      <div className="mt-1 flex gap-[2px] text-[10px] text-slate-500">
        {data.map((d, i) => (
          <div key={i} className="flex-1 truncate text-center">
            {i % labelEvery === 0 ? d.label : ""}
          </div>
        ))}
      </div>
    </div>
  );
}

/** Ranked horizontal bars (top products, categories...). */
export function RankBars({ data, format }: { data: BarDatum[]; format: (n: number) => string }) {
  const max = Math.max(...data.map((d) => d.value), 0) || 1;
  return (
    <ul className="space-y-2.5">
      {data.map((d) => (
        <li key={d.label} title={`${d.label}: ${format(d.value)}`}>
          <div className="mb-1 flex justify-between gap-2 text-sm">
            <span className="truncate text-slate-700">{d.label}</span>
            <span className="shrink-0 font-medium text-slate-900">
              {format(d.value)}
              {d.hint && <span className="ms-1 text-xs font-normal text-slate-500">{d.hint}</span>}
            </span>
          </div>
          <div className="h-2 rounded-full bg-slate-100">
            <div className="h-2 rounded-full bg-brand-600" style={{ width: `${(Math.max(d.value, 0) / max) * 100}%` }} />
          </div>
        </li>
      ))}
    </ul>
  );
}
