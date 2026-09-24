"use client";

import { useEffect, useRef, useState } from "react";

export interface BarDatum {
  label: string;
  value: number;
  hint?: string;
}

const LABEL_SPACE = 44; // px each axis label needs to stay readable

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
  const [width, setWidth] = useState(0);
  const ref = useRef<HTMLDivElement>(null);
  const max = Math.max(...data.map((d) => d.value), 0) || 1;
  const n = data.length;

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Show as many labels as fit; always keep the newest (last) bar labeled.
  const step = width > 0 ? Math.max(1, Math.ceil((n * LABEL_SPACE) / width)) : Math.ceil(n / 6);
  const showLabel = (i: number) => (n - 1 - i) % step === 0;
  const align = (i: number) => (i < n * 0.2 ? "start" : i > n * 0.8 ? "end" : "center");

  return (
    <div ref={ref} className="relative" dir="ltr">
      <div className="flex items-end gap-[2px] border-b border-slate-200" style={{ height }}>
        {data.map((d, i) => {
          const h = Math.max((Math.max(d.value, 0) / max) * (height - 8), d.value > 0 ? 2 : 0);
          const a = align(i);
          return (
            <div
              key={i}
              className="relative flex h-full min-w-0 flex-1 items-end justify-center"
              onMouseEnter={() => setHover(i)}
              onMouseLeave={() => setHover(null)}
              onTouchStart={() => setHover(i)}
            >
              <div
                className={`w-full max-w-9 rounded-t-[4px] transition-colors ${hover === i ? "bg-brand-800" : "bg-brand-600"}`}
                style={{ height: h }}
              />
              {hover === i && (
                <div
                  className={`pointer-events-none absolute bottom-full z-10 mb-1 whitespace-nowrap rounded-md bg-slate-900 px-2 py-1 text-center text-xs text-white shadow ${
                    a === "start" ? "left-0" : a === "end" ? "right-0" : "left-1/2 -translate-x-1/2"
                  }`}
                >
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
      <div className="relative mt-1 h-4 text-[10px] text-slate-500">
        {data.map((d, i) => {
          if (!showLabel(i)) return null;
          const center = ((i + 0.5) / n) * 100;
          const a = align(i);
          const style =
            a === "start"
              ? { left: `${Math.max(center - 50 / n, 0)}%` }
              : a === "end"
                ? { right: `${Math.max(100 - center - 50 / n, 0)}%` }
                : { left: `${center}%`, transform: "translateX(-50%)" };
          return (
            <span key={i} className="absolute top-0 whitespace-nowrap" style={style}>
              {d.label}
            </span>
          );
        })}
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
