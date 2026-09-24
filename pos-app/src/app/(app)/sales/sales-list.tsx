"use client";

import { Search } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, EmptyState, Input, Loading, PageHeader, Select, Table, useToast } from "@/components/ui";
import { SALE_STATUS_LABELS, dateTime, errorMessage, isoDay, money } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Sale, SaleStatus } from "@/lib/types";

type Row = Sale & { customer: { name: string } | null; cashier: { full_name: string } | null };

const STATUS_TONE: Record<SaleStatus, "green" | "amber" | "red"> = {
  completed: "green",
  partially_returned: "amber",
  returned: "red",
};

const PAGE = 50;

export function SalesList() {
  const toast = useToast();
  const { isManager } = useSession();
  const [from, setFrom] = useState(() => isoDay(new Date(Date.now() - 6 * 864e5)));
  const [to, setTo] = useState(() => isoDay());
  const [q, setQ] = useState("");
  const [status, setStatus] = useState("");
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(false);

  const load = useCallback(
    async (pageNo: number) => {
      setLoading(true);
      let req = supabase()
        .from("sales")
        .select("*, customer:customers(name), cashier:profiles(full_name)")
        .order("created_at", { ascending: false })
        .range(pageNo * PAGE, pageNo * PAGE + PAGE);
      if (q.trim()) {
        req = req.ilike("invoice_no", `%${q.trim().replace(/[%,]/g, "")}%`);
      } else {
        req = req.gte("created_at", `${from}T00:00:00+03:00`).lte("created_at", `${to}T23:59:59.999+03:00`);
      }
      if (status) req = req.eq("status", status);
      const { data, error } = await req;
      if (error) toast(errorMessage(error), "error");
      const list = (data ?? []) as Row[];
      setHasMore(list.length > PAGE);
      setRows((prev) => (pageNo === 0 ? list.slice(0, PAGE) : [...prev, ...list.slice(0, PAGE)]));
      setLoading(false);
    },
    [from, to, q, status, toast],
  );

  useEffect(() => {
    const t = setTimeout(() => {
      setPage(0);
      load(0);
    }, 250);
    return () => clearTimeout(t);
  }, [load]);

  const total = rows.reduce((s, r) => s + Number(r.total), 0);

  return (
    <div className="p-4 md:p-6">
      <PageHeader title="الفواتير" subtitle={isManager ? "جميع فواتير المتجر" : "فواتيرك"} />
      <Card>
        <div className="flex flex-wrap items-end gap-2 border-b border-slate-100 p-3">
          <div className="relative min-w-48 flex-1">
            <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <Input className="ps-9" dir="ltr" placeholder="رقم الفاتورة INV-..." value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
          <Input type="date" className="w-auto" value={from} onChange={(e) => setFrom(e.target.value)} disabled={!!q} />
          <Input type="date" className="w-auto" value={to} onChange={(e) => setTo(e.target.value)} disabled={!!q} />
          <Select className="w-auto" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">كل الحالات</option>
            {Object.entries(SALE_STATUS_LABELS).map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
          </Select>
        </div>
        {loading && rows.length === 0 ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد فواتير في هذه الفترة" />
        ) : (
          <>
            <Table>
              <thead>
                <tr>
                  <th>رقم الفاتورة</th>
                  <th>التاريخ</th>
                  <th>العميل</th>
                  <th>الكاشير</th>
                  <th>الإجمالي</th>
                  <th>المرتجع</th>
                  <th>الحالة</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((s) => (
                  <tr key={s.id}>
                    <td>
                      <Link href={`/sales/${s.id}`} className="font-medium text-brand-700 hover:underline">
                        {s.invoice_no}
                      </Link>
                    </td>
                    <td className="ltr-nums text-slate-600">{dateTime(s.created_at)}</td>
                    <td>{s.customer?.name ?? "-"}</td>
                    <td>{s.cashier?.full_name ?? "-"}</td>
                    <td className="font-semibold">{money(s.total)}</td>
                    <td className="text-red-600">{Number(s.returned_amount) > 0 ? money(s.returned_amount) : "-"}</td>
                    <td>
                      <Badge tone={STATUS_TONE[s.status]}>{SALE_STATUS_LABELS[s.status]}</Badge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
            <div className="flex items-center justify-between border-t border-slate-100 p-3 text-sm">
              <span className="text-slate-600">
                {rows.length} فاتورة · المجموع {money(total)}
              </span>
              {hasMore && (
                <Button
                  variant="outline"
                  size="sm"
                  loading={loading}
                  onClick={() => {
                    const next = page + 1;
                    setPage(next);
                    load(next);
                  }}
                >
                  عرض المزيد
                </Button>
              )}
            </div>
          </>
        )}
      </Card>
    </div>
  );
}
