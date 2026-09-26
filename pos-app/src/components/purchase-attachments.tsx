"use client";

import { FileText, Paperclip, Upload } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { dateTime, errorMessage } from "@/lib/format";
import { openPurchaseAttachment, uploadPurchaseAttachment } from "@/lib/purchasing";
import { supabase } from "@/lib/supabase/client";
import { Button, Card, useToast } from "./ui";

interface Attachment {
  id: string;
  file_path: string;
  file_name: string;
  mime_type: string;
  size_bytes: number;
  created_at: string;
}

/** مرفقات مستند شراء (PDF أو صور حتى 10MB) في مخزن خاص — للمدير فقط */
export function PurchaseAttachments({ ownerType, ownerId }: { ownerType: string; ownerId: string }) {
  const toast = useToast();
  const [items, setItems] = useState<Attachment[]>([]);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);

  const load = useCallback(async () => {
    const { data } = await supabase()
      .from("purchase_attachments")
      .select("id, file_path, file_name, mime_type, size_bytes, created_at")
      .eq("owner_type", ownerType)
      .eq("owner_id", ownerId)
      .order("created_at");
    setItems((data ?? []) as Attachment[]);
  }, [ownerType, ownerId]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    load();
  }, [load]);

  const onFiles = async (files: FileList | null) => {
    if (!files?.length) return;
    setBusy(true);
    try {
      for (const f of Array.from(files)) {
        if (f.size > 10 * 1024 * 1024) throw new Error(`${f.name}: الحجم أكبر من 10MB`);
        if (!["application/pdf", "image/jpeg", "image/png", "image/webp"].includes(f.type)) throw new Error(`${f.name}: PDF أو صورة فقط`);
        await uploadPurchaseAttachment(ownerType, ownerId, f);
      }
      toast("تم رفع المرفق");
      load();
    } catch (e) {
      toast(errorMessage(e), "error");
    } finally {
      setBusy(false);
      if (input.current) input.current.value = "";
    }
  };

  return (
    <Card className="p-4">
      <div className="mb-2 flex items-center justify-between gap-2">
        <h3 className="flex items-center gap-1.5 font-semibold text-slate-900">
          <Paperclip className="size-4" /> المرفقات
        </h3>
        <Button size="sm" variant="outline" loading={busy} onClick={() => input.current?.click()}>
          <Upload className="size-4" /> رفع
        </Button>
        <input
          ref={input}
          type="file"
          multiple
          accept="application/pdf,image/jpeg,image/png,image/webp"
          className="hidden"
          aria-label="رفع مرفق"
          onChange={(e) => onFiles(e.target.files)}
        />
      </div>
      {items.length === 0 ? (
        <p className="text-sm text-slate-500">لا توجد مرفقات — ارفع صورة الفاتورة أو سند الاستلام.</p>
      ) : (
        <ul className="space-y-1.5">
          {items.map((a) => (
            <li key={a.id}>
              <button
                type="button"
                className="flex w-full items-center gap-2 rounded-lg p-1.5 text-start text-sm hover:bg-slate-50"
                onClick={() => openPurchaseAttachment(a.file_path).catch((e) => toast(errorMessage(e), "error"))}
              >
                <FileText className="size-4 shrink-0 text-slate-400" />
                <span className="min-w-0 flex-1 truncate">{a.file_name}</span>
                <span className="ltr-nums shrink-0 text-xs text-slate-500">
                  {Math.ceil(a.size_bytes / 1024)}KB · {dateTime(a.created_at)}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
