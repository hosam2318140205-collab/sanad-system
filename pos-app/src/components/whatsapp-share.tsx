"use client";

import { MessageCircle } from "lucide-react";
import { useState } from "react";
import { openWhatsApp, receiptMessage, waPhone } from "@/lib/customers";
import { errorMessage } from "@/lib/format";
import type { ReceiptData } from "./receipt";
import { useSession } from "./session-context";
import { Button, Input, Modal, useToast } from "./ui";

/** زر إرسال الفاتورة عبر واتساب: رسالة جاهزة + رابط الفاتورة، والرقم قابل للتعديل. */
export function WhatsAppReceiptButton({ data }: { data: ReceiptData }) {
  const { settings } = useSession();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [phone, setPhone] = useState("");
  const onAccount = data.payments.filter((p) => p.method === "on_account").reduce((s, p) => s + Number(p.amount), 0);

  const text = receiptMessage({
    settings,
    customerName: data.customerName,
    invoiceNo: data.sale.invoice_no,
    createdAt: data.sale.created_at,
    total: Number(data.sale.total),
    vat: Number(data.sale.vat_amount),
    pointsEarned: Number(data.sale.loyalty_points_earned ?? 0),
    pointsBalance: data.customerPoints,
    onAccount,
    token: data.sale.public_token,
  });
  const normalized = waPhone(phone);

  const send = async () => {
    if (!normalized) return;
    try {
      await openWhatsApp({ phone: normalized, text, kind: "receipt", saleId: data.sale.id, customerId: data.customerId });
      setOpen(false);
    } catch (e) {
      toast(errorMessage(e), "error");
    }
  };

  return (
    <>
      <Button
        variant="outline"
        className="border-emerald-600 text-emerald-700 hover:bg-emerald-50"
        onClick={() => {
          setPhone(data.customerPhone ?? "");
          setOpen(true);
        }}
      >
        <MessageCircle className="size-4" /> واتساب
      </Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="إرسال الفاتورة عبر واتساب"
        size="sm"
        footer={
          <Button onClick={send} disabled={!normalized} className="bg-emerald-600 hover:bg-emerald-700">
            <MessageCircle className="size-4" /> فتح واتساب
          </Button>
        }
      >
        <div className="space-y-3">
          <label className="block space-y-1">
            <span className="text-sm font-medium text-slate-700">رقم جوال العميل</span>
            <Input dir="ltr" inputMode="tel" placeholder="05xxxxxxxx" value={phone} onChange={(e) => setPhone(e.target.value)} autoFocus />
          </label>
          {phone && !normalized && <p className="text-xs text-red-600">رقم غير صحيح</p>}
          <pre className="max-h-48 overflow-y-auto whitespace-pre-wrap rounded-lg bg-slate-50 p-3 text-xs leading-relaxed text-slate-700" data-testid="wa-preview">
            {text}
          </pre>
          <p className="text-xs text-slate-500">يُفتح واتساب برسالة جاهزة ورابط الفاتورة. يُسجَّل الإرسال في ملف العميل.</p>
        </div>
      </Modal>
    </>
  );
}
