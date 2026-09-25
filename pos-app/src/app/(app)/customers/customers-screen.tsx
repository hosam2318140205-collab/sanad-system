"use client";

import { BarChart3, Plus, Search, Wallet } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Button, Card, EmptyState, Input, Loading, PageHeader, Table, cn, useToast } from "@/components/ui";
import { dateOnly, errorMessage, money } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Customer } from "@/lib/types";
import { CustomerFormModal } from "./customer-form";

type Row = Customer & {
  account: { account_balance: number; loyalty_points: number; credit_limit: number | null } | null;
};

export function CustomersScreen() {
  const toast = useToast();
  const router = useRouter();
  const { isManager, settings } = useSession();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [q, setQ] = useState("");
  const [adding, setAdding] = useState(false);

  const load = useCallback(async () => {
    let req = supabase()
      .from("customers")
      .select("*, account:customer_accounts(account_balance, loyalty_points, credit_limit)")
      .order("created_at", { ascending: false })
      .limit(200);
    const term = q.trim().replace(/[%,()]/g, "");
    if (term) req = req.or(`name.ilike.%${term}%,phone.ilike.%${term}%`);
    const { data, error } = await req;
    if (error) toast(errorMessage(error), "error");
    // علاقة واحد لواحد: PostgREST قد يعيد كائناً أو مصفوفة
    setRows(
      ((data ?? []) as Array<Customer & { account: Row["account"] | Row["account"][] }>).map((c) => ({
        ...c,
        account: Array.isArray(c.account) ? (c.account[0] ?? null) : c.account,
      })),
    );
  }, [q, toast]);

  useEffect(() => {
    const t = setTimeout(load, 250);
    return () => clearTimeout(t);
  }, [load]);

  const balance = (r: Row) => Number(r.account?.account_balance ?? 0);

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="العملاء"
        actions={
          <>
            {isManager && (
              <>
                <Link href="/customers/receivables">
                  <Button variant="outline">
                    <Wallet className="size-4" /> الذمم والتحصيل
                  </Button>
                </Link>
                <Link href="/customers/analytics">
                  <Button variant="outline">
                    <BarChart3 className="size-4" /> التحليلات
                  </Button>
                </Link>
              </>
            )}
            <Button onClick={() => setAdding(true)}>
              <Plus className="size-4" /> عميل جديد
            </Button>
          </>
        }
      />
      <Card>
        <div className="border-b border-slate-100 p-3">
          <div className="relative">
            <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <Input className="ps-9" placeholder="بحث بالاسم أو الجوال" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
        </div>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا يوجد عملاء" />
        ) : (
          <>
            <ul className="divide-y divide-slate-100 md:hidden">
              {rows.map((c) => (
                <li key={c.id}>
                  <Link href={`/customers/${c.id}`} className="flex items-center gap-3 p-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-medium">{c.name}</p>
                      <p className="ltr-nums text-xs text-slate-500">{c.phone ?? "—"}</p>
                    </div>
                    <div className="text-end text-xs">
                      {settings.loyalty_enabled && <p className="text-amber-700">{c.account?.loyalty_points ?? 0} نقطة</p>}
                      {balance(c) !== 0 && (
                        <p className={cn("font-semibold", balance(c) > 0 ? "text-red-600" : "text-emerald-700")}>
                          {balance(c) > 0 ? "عليه" : "له"} {money(Math.abs(balance(c)))}
                        </p>
                      )}
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
            <Table className="hidden md:block">
              <thead>
                <tr>
                  <th>الاسم</th>
                  <th>الجوال</th>
                  <th>المدينة</th>
                  {settings.loyalty_enabled && <th>النقاط</th>}
                  <th>الرصيد</th>
                  <th>حد الائتمان</th>
                  <th>تاريخ التسجيل</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((c) => (
                  <tr key={c.id} className="cursor-pointer" onClick={() => router.push(`/customers/${c.id}`)}>
                    <td className="font-medium">{c.name}</td>
                    <td className="ltr-nums">{c.phone ?? "-"}</td>
                    <td>{c.city ?? "-"}</td>
                    {settings.loyalty_enabled && <td className="tabular-nums">{c.account?.loyalty_points ?? 0}</td>}
                    <td className={cn("tabular-nums", balance(c) > 0 ? "font-semibold text-red-600" : balance(c) < 0 ? "text-emerald-700" : "text-slate-400")}>
                      {balance(c) === 0 ? "—" : `${balance(c) > 0 ? "عليه" : "له"} ${money(Math.abs(balance(c)))}`}
                    </td>
                    <td className="tabular-nums">{c.account?.credit_limit != null ? money(c.account.credit_limit) : "—"}</td>
                    <td className="ltr-nums">{dateOnly(c.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </>
        )}
      </Card>

      <CustomerFormModal
        open={adding}
        customer={null}
        onClose={() => setAdding(false)}
        onSaved={(c) => {
          setAdding(false);
          router.push(`/customers/${c.id}`);
        }}
      />
    </div>
  );
}
