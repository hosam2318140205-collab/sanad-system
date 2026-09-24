"use client";

import { Clock } from "lucide-react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui";
import { supabase } from "@/lib/supabase/client";

export default function PendingPage() {
  const router = useRouter();
  return (
    <div className="flex min-h-dvh items-center justify-center p-4">
      <div className="max-w-sm rounded-2xl bg-white p-8 text-center shadow">
        <Clock className="mx-auto mb-3 size-10 text-amber-500" />
        <h1 className="mb-2 text-xl font-bold">الحساب بانتظار التفعيل</h1>
        <p className="mb-5 text-sm text-slate-600">يرجى التواصل مع مالك المتجر لتفعيل حسابك وتحديد صلاحياتك.</p>
        <Button
          variant="outline"
          onClick={async () => {
            await supabase().auth.signOut();
            router.replace("/login");
          }}
        >
          تسجيل الخروج
        </Button>
      </div>
    </div>
  );
}
