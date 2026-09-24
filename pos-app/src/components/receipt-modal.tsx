"use client";

import { Printer } from "lucide-react";
import { useState, type ReactNode } from "react";
import { printNow } from "@/lib/sales";
import { PrintPortal } from "./print-portal";
import { Receipt, type ReceiptData } from "./receipt";
import { useSession } from "./session-context";
import { Button, Modal } from "./ui";

export function ReceiptModal({
  data,
  onClose,
  title = "الفاتورة",
  extraActions,
}: {
  data: ReceiptData | null;
  onClose: () => void;
  title?: string;
  extraActions?: ReactNode;
}) {
  const { settings } = useSession();
  const [width, setWidth] = useState<"80" | "58">("80");
  if (!data) return null;
  return (
    <>
      <Modal
        open
        onClose={onClose}
        title={title}
        size="md"
        footer={
          <>
            <select
              className="h-10 rounded-lg border border-slate-300 px-2 text-sm"
              value={width}
              onChange={(e) => setWidth(e.target.value as "80" | "58")}
              aria-label="عرض الورق"
            >
              <option value="80">ورق 80mm</option>
              <option value="58">ورق 58mm</option>
            </select>
            {extraActions}
            <Button onClick={printNow} autoFocus>
              <Printer className="size-4" /> طباعة
            </Button>
          </>
        }
      >
        <div className="flex justify-center rounded-lg bg-slate-100 p-3">
          <div className="shadow">
            <Receipt data={data} settings={settings} width={width} />
          </div>
        </div>
      </Modal>
      <PrintPortal>
        <Receipt data={data} settings={settings} width={width} />
      </PrintPortal>
    </>
  );
}
