"use client";

import { Plus } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { useSession } from "@/components/session-context";
import { Badge, Button, Card, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, Table, useToast } from "@/components/ui";
import { dateTime, errorMessage } from "@/lib/format";
import { fetchLocations, type Location } from "@/lib/inventory";
import { supabase } from "@/lib/supabase/client";
import type { Category, CountStatus, StockCount } from "@/lib/types";

const STATUS: Record<CountStatus, { label: string; tone: "blue" | "green" | "slate" | "amber" }> = {
  open: { label: "مفتوح", tone: "blue" },
  submitted: { label: "بانتظار اعتماد المدير", tone: "amber" },
  applied: { label: "معتمد", tone: "green" },
  cancelled: { label: "ملغي", tone: "slate" },
};

type Row = StockCount & { category: { name: string } | null; location: { name: string } | null };

export function CountsList() {
  const toast = useToast();
  const router = useRouter();
  const { isManager } = useSession();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [categories, setCategories] = useState<Category[]>([]);
  const [locations, setLocations] = useState<Location[]>([]);
  const [loc, setLoc] = useState("");
  const [open, setOpen] = useState(false);
  const [cat, setCat] = useState("");
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const db = supabase();
    db.from("stock_counts")
      .select("*, category:categories(name), location:locations(name)")
      .order("created_at", { ascending: false })
      .limit(100)
      .then(({ data }) => setRows((data ?? []) as Row[]));
    db.from("categories")
      .select("*")
      .order("sort_order")
      .then(({ data }) => setCategories((data ?? []) as Category[]));
    fetchLocations()
      .then((l) => {
        setLocations(l);
        setLoc(l[0]?.id ?? "");
      })
      .catch(() => setLocations([]));
  }, []);

  const start = async () => {
    setBusy(true);
    const { data, error } = await supabase().rpc("start_location_count", { p_location: loc, p_category_id: cat || null, p_notes: notes || null });
    setBusy(false);
    if (error) return toast(errorMessage(error), "error");
    router.push(`/inventory/counts/${data as string}`);
  };

  return (
    <div className="p-4 md:p-6">
      <PageHeader
        title="الجرد"
        subtitle="جرد لكل موقع — امسح الباركود أو SKU من الجوال أو القارئ، والفروقات لا تُعتمد إلا بموافقة المدير"
        actions={
          isManager && (
            <Button onClick={() => setOpen(true)}>
              <Plus className="size-4" /> جرد جديد
            </Button>
          )
        }
      />
      <Card>
        {rows === null ? (
          <Loading />
        ) : rows.length === 0 ? (
          <EmptyState title="لا توجد عمليات جرد" />
        ) : (
          <Table>
            <thead>
              <tr>
                <th>رقم الجرد</th>
                <th>الموقع</th>
                <th>النطاق</th>
                <th>تاريخ البدء</th>
                <th>الاعتماد</th>
                <th>الحالة</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.id}>
                  <td>
                    <Link className="font-medium text-brand-700 hover:underline" href={`/inventory/counts/${c.id}`}>
                      {c.count_no}
                    </Link>
                    {c.notes && <p className="text-xs text-slate-500">{c.notes}</p>}
                  </td>
                  <td>{c.location?.name ?? "إجمالي (جرد قديم)"}</td>
                  <td>{c.category?.name ?? "كل المخزون"}</td>
                  <td className="ltr-nums">{dateTime(c.created_at)}</td>
                  <td className="ltr-nums">{dateTime(c.applied_at)}</td>
                  <td>
                    <Badge tone={STATUS[c.status].tone}>{STATUS[c.status].label}</Badge>
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="بدء جرد جديد"
        size="sm"
        footer={
          <Button onClick={start} loading={busy} disabled={!loc}>
            بدء الجرد
          </Button>
        }
      >
        <div className="space-y-3">
          <Field label="الموقع">
            <Select aria-label="موقع الجرد" value={loc} onChange={(e) => setLoc(e.target.value)}>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="النطاق">
            <Select value={cat} onChange={(e) => setCat(e.target.value)}>
              <option value="">كل المخزون</option>
              {categories.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="ملاحظات">
            <Input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="جرد نهاية الشهر" />
          </Field>
          <p className="text-xs text-slate-500">
            تُلتقط أرصدة الموقع لحظة البدء. البيع مستمر أثناء الجرد: أي حركة بعد اللقطة وقبل عدّ الصنف تُحسب تلقائياً فلا تظهر فروقات وهمية.
          </p>
        </div>
      </Modal>
    </div>
  );
}
