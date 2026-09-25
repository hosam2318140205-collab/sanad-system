import { isoDay } from "./format";

/** Common report ranges in Riyadh time (YYYY-MM-DD, inclusive). */
export function presets() {
  const now = new Date();
  const today = isoDay(now);
  const d = (offset: number) => isoDay(new Date(now.getTime() - offset * 864e5));
  const [y, m] = today.split("-").map(Number);
  const monthStart = `${y}-${String(m).padStart(2, "0")}-01`;
  const lastMonthEnd = isoDay(new Date(Date.UTC(y, m - 1, 0)));
  const lastMonthStart = lastMonthEnd.slice(0, 8) + "01";
  return [
    { key: "today", label: "اليوم", from: today, to: today },
    { key: "yesterday", label: "أمس", from: d(1), to: d(1) },
    { key: "7", label: "آخر 7 أيام", from: d(6), to: today },
    { key: "month", label: "هذا الشهر", from: monthStart, to: today },
    { key: "last_month", label: "الشهر الماضي", from: lastMonthStart, to: lastMonthEnd },
    { key: "year", label: "هذه السنة", from: `${y}-01-01`, to: today },
  ];
}
