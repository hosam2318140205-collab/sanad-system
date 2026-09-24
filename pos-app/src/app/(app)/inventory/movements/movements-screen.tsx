"use client";

import { ArrowRight } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import { Badge, Button, Card, EmptyState, Input, Loading, PageHeader, Select, Table } from "@/components/ui";
import { MOVEMENT_LABELS, dateTime, isoDay, variantLabel } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { MovementType, StockMovement } from "@/lib/types";

type Row = StockMovement & {
  variant: { sku: string; size: string | null; color: string | null; product: { name: string } } | null;
  user: { full_name: string } | null;
};

export function MovementsScreen() {
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [type, setType] = useState("");
  const [from, setFrom] = useState(() => isoDay(new Date(Date.now() - 6 * 864e5)));
  const [to, setTo] = useState(() => isoDay());

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      let req = supabase()
        .from("stock_movements")
        .select("*, variant:product_variants(sku, size, color, product:products(name)), user:profiles(full_name)")
        .gte("created_at", `${from}T00:00:00+03:00`)
        .lte("created_at", `${to}T23:59:59.999+03:00`)
        .order("created_at", { ascending: false })
        .limit(500);
      if (type) req = req.eq("type", type);
      const { data } = await req;
      if (cancelled) return;
      setRows((data ?? []) as unknown as Row[]);
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [type, from, to]);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="حركات المخزون"
        subtitle="كل تغيير في الكميات مسجل هنا"
        actions={
          <Link href="/inventory">
            <Button variant="ghost">
              <ArrowRight className="size-4" /> المخزون
            </Button>
          </Link>
        }
      />
      <Card>
        <div className="flex flex-wrap gap-2 border-b border-slate-100 p-3">
          <Input type="date" className="w-auto" value={from} onChange={(e) => setFrom(e.target.value)} />
          <Input type="date" className="w-auto" value={to} onChange={(e) => setTo(e.target.value)} />
          <Select className="w-auto" value={type} onChange={(e) => setType(e.target.value)}>
            <option value="">كل الأنواع</option>
            {(Object.keys(MOVEMENT_LABELS) as MovementType[]).map((t) => (
              <option key={t} value={t}>
                {MOVEMENT_LABELS[t]}
              </option>
            ))}
          </Select>
        </div>
        {loading ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد حركات" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>التاريخ</th>
                <th>الصنف</th>
                <th>النوع</th>
                <th>الكمية</th>
                <th>الرصيد بعد</th>
                <th>ملاحظة</th>
                <th>المستخدم</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((m) => (
                <tr key={m.id}>
                  <td className="ltr-nums text-slate-600">{dateTime(m.created_at)}</td>
                  <td>
                    <p className="font-medium">{m.variant?.product.name}</p>
                    <p className="text-xs text-slate-500">
                      {variantLabel(m.variant?.size, m.variant?.color)} · <span dir="ltr">{m.variant?.sku}</span>
                    </p>
                  </td>
                  <td>
                    <Badge tone={m.qty_change > 0 ? "green" : "red"}>{MOVEMENT_LABELS[m.type]}</Badge>
                  </td>
                  <td className={`ltr-nums font-semibold ${m.qty_change > 0 ? "text-emerald-700" : "text-red-600"}`}>
                    {m.qty_change > 0 ? `+${m.qty_change}` : m.qty_change}
                  </td>
                  <td>{m.balance_after}</td>
                  <td className="max-w-60 truncate text-slate-600">{m.note ?? "-"}</td>
                  <td>{m.user?.full_name ?? "-"}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}
