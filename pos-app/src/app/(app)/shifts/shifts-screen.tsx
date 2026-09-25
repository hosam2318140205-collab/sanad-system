"use client";

import { ArrowDownToLine, ArrowUpFromLine, Lock, PlayCircle } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import {
  CashMovementModal,
  CloseShiftModal,
  OpenShiftModal,
  ShiftReportModal,
  differenceLabel,
} from "@/components/shift-dialogs";
import { Badge, Button, Card, EmptyState, Input, Loading, PageHeader, Stat, Table, useToast } from "@/components/ui";
import { dateTime, errorMessage, isoDay, money, num } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { ShiftListRow, ShiftSummary } from "@/lib/types";

export function ShiftsScreen() {
  const toast = useToast();
  const { profile, isManager, settings } = useSession();
  const [current, setCurrent] = useState<ShiftSummary | null | undefined>(undefined);
  const [rows, setRows] = useState<ShiftListRow[] | null>(null);
  const [from, setFrom] = useState(() => isoDay(new Date(Date.now() - 6 * 864e5)));
  const [to, setTo] = useState(() => isoDay());
  const [openModal, setOpenModal] = useState(false);
  const [movement, setMovement] = useState<"in" | "out" | null>(null);
  const [closing, setClosing] = useState<{ id: string; shift_no: string; cashier_name?: string | null } | null>(null);
  const [viewing, setViewing] = useState<string | null>(null);

  const loadCurrent = useCallback(async () => {
    const db = supabase();
    const { data: s } = await db
      .from("shifts")
      .select("id")
      .eq("cashier_id", profile.id)
      .eq("status", "open")
      .maybeSingle();
    if (!s) return setCurrent(null);
    const { data, error } = await db.rpc("shift_summary", { p_shift_id: (s as { id: string }).id });
    if (error) toast(errorMessage(error), "error");
    setCurrent((data as ShiftSummary) ?? null);
  }, [profile.id, toast]);

  const loadList = useCallback(async () => {
    const { data, error } = await supabase().rpc("list_shifts", { p_from: from, p_to: to });
    if (error) toast(errorMessage(error), "error");
    setRows((data ?? []) as ShiftListRow[]);
  }, [from, to, toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    loadCurrent();
  }, [loadCurrent]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reload when the range changes
    loadList();
  }, [loadList]);

  const refresh = () => {
    loadCurrent();
    loadList();
  };

  const n = current?.numbers;
  const openShifts = rows?.filter((r) => r.status === "open").length ?? 0;
  const closedWithDiff = rows?.filter((r) => r.status === "closed" && Math.abs(Number(r.cash_difference ?? 0)) >= 0.005).length ?? 0;

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="الورديات"
        subtitle={settings.require_shift ? "البيع يتطلب وردية مفتوحة" : "الورديات اختيارية (يمكن تغييرها من الإعدادات)"}
      />

      {/* الوردية الحالية */}
      <Card className="mb-4 p-4">
        {current === undefined ? (
          <Loading />
        ) : current === null ? (
          <div className="flex flex-col items-center gap-3 py-6 text-center">
            <p className="font-medium text-slate-700">لا توجد لديك وردية مفتوحة</p>
            <Button size="lg" onClick={() => setOpenModal(true)}>
              <PlayCircle className="size-5" /> فتح وردية
            </Button>
          </div>
        ) : (
          <div className="space-y-4">
            <div className="flex flex-wrap items-center gap-2">
              <h2 className="text-lg font-semibold">ورديتي {current.shift_no}</h2>
              <Badge tone="blue">مفتوحة</Badge>
              <span className="ltr-nums text-sm text-slate-500">منذ {dateTime(current.opened_at)}</span>
            </div>
            <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
              <Stat label="الرصيد الافتتاحي" value={money(n?.opening_cash)} />
              <Stat label="الفواتير" value={num(n?.sales_count)} hint={`مرتجعات ${num(n?.returns_count)}`} />
              <Stat label="إجمالي المبيعات" value={money(n?.total_sales)} tone="green" />
              {n?.expected_cash !== undefined && <Stat label="النقد المتوقع في الدرج" value={money(n.expected_cash)} tone="blue" />}
            </div>
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" onClick={() => setMovement("in")}>
                <ArrowDownToLine className="size-4" /> إيداع نقدي
              </Button>
              <Button variant="outline" onClick={() => setMovement("out")}>
                <ArrowUpFromLine className="size-4" /> سحب نقدي
              </Button>
              <Button variant="outline" onClick={() => setViewing(current.id)}>
                عرض الملخص
              </Button>
              <Button className="ms-auto" onClick={() => setClosing({ id: current.id, shift_no: current.shift_no })}>
                <Lock className="size-4" /> إغلاق الوردية
              </Button>
            </div>
          </div>
        )}
      </Card>

      {isManager && rows && (
        <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Stat label="ورديات مفتوحة الآن" value={num(openShifts)} tone="blue" />
          <Stat label="ورديات بفروقات" value={num(closedWithDiff)} tone={closedWithDiff ? "red" : "green"} hint="في الفترة المحددة" />
        </div>
      )}

      {/* سجل الورديات */}
      <Card>
        <div className="flex flex-wrap items-center gap-2 border-b border-slate-100 p-3">
          <p className="font-semibold">{isManager ? "كل الورديات" : "ورديّاتي"}</p>
          <div className="flex w-full items-center gap-2 sm:ms-auto sm:w-auto">
            <Input type="date" className="min-w-0 flex-1 sm:w-auto sm:flex-none" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="من تاريخ" />
            <span className="text-slate-400">—</span>
            <Input type="date" className="min-w-0 flex-1 sm:w-auto sm:flex-none" value={to} onChange={(e) => setTo(e.target.value)} aria-label="إلى تاريخ" />
          </div>
        </div>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد ورديات في هذه الفترة" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>الوردية</th>
                {isManager && <th>الموظف</th>}
                <th>الفتح</th>
                <th>الإغلاق</th>
                <th>المبيعات</th>
                <th>المتوقع</th>
                <th>المعدود</th>
                <th>النتيجة</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const d = differenceLabel(r.cash_difference);
                return (
                  <tr key={r.id} className="cursor-pointer" onClick={() => setViewing(r.id)}>
                    <td className="font-medium text-brand-700">{r.shift_no}</td>
                    {isManager && <td>{r.cashier_name}</td>}
                    <td className="ltr-nums text-slate-600">{dateTime(r.opened_at)}</td>
                    <td className="ltr-nums text-slate-600">{r.closed_at ? dateTime(r.closed_at) : "-"}</td>
                    <td>{money(r.total_sales)}</td>
                    <td>{r.expected_cash === null ? "-" : money(r.expected_cash)}</td>
                    <td>{r.counted_cash === null ? "-" : money(r.counted_cash)}</td>
                    <td>{r.status === "open" ? <Badge tone="blue">مفتوحة</Badge> : <Badge tone={d.tone}>{d.text}</Badge>}</td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>

      <OpenShiftModal
        open={openModal}
        onClose={() => setOpenModal(false)}
        onOpened={() => {
          setOpenModal(false);
          refresh();
        }}
      />
      <CashMovementModal
        type={movement}
        onClose={() => setMovement(null)}
        onDone={() => {
          setMovement(null);
          refresh();
        }}
      />
      <CloseShiftModal
        shift={closing}
        onClose={() => setClosing(null)}
        onClosed={(s) => {
          setClosing(null);
          toast(s.cash_difference !== null ? `تم إغلاق الوردية — ${differenceLabel(s.cash_difference).text}` : "تم إغلاق الوردية");
          refresh();
          setViewing(s.id);
        }}
      />
      <ShiftReportModal
        shiftId={viewing}
        onClose={() => setViewing(null)}
        onRequestClose={(s) => {
          setViewing(null);
          setClosing({ id: s.id, shift_no: s.shift_no, cashier_name: s.cashier_name });
        }}
      />
    </div>
  );
}
