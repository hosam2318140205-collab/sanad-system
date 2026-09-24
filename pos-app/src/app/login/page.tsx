"use client";

import { Shirt } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { Button, Field, Input } from "@/components/ui";
import { supabase } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);
    const { error } = await supabase().auth.signInWithPassword({ email: email.trim(), password });
    setLoading(false);
    if (error) {
      setError(error.message === "Invalid login credentials" ? "البريد أو كلمة المرور غير صحيحة" : error.message);
      return;
    }
    router.replace("/");
    router.refresh();
  };

  return (
    <div className="flex min-h-dvh items-center justify-center bg-gradient-to-br from-brand-900 via-slate-900 to-slate-950 p-4">
      <div className="w-full max-w-sm rounded-2xl bg-white p-7 shadow-2xl">
        <div className="mb-6 flex flex-col items-center gap-2 text-center">
          <div className="rounded-2xl bg-brand-700 p-3 text-white">
            <Shirt className="size-8" />
          </div>
          <h1 className="text-2xl font-bold text-slate-900">نظام الكاشير</h1>
          <p className="text-sm text-slate-500">سجّل الدخول للمتابعة</p>
        </div>
        <form onSubmit={onSubmit} className="space-y-4">
          <Field label="البريد الإلكتروني">
            <Input
              type="email"
              dir="ltr"
              autoComplete="username"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </Field>
          <Field label="كلمة المرور">
            <Input
              type="password"
              dir="ltr"
              autoComplete="current-password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </Field>
          {error && <p className="rounded-lg bg-red-50 p-2.5 text-sm text-red-700">{error}</p>}
          <Button type="submit" size="lg" className="w-full" loading={loading}>
            دخول
          </Button>
        </form>
      </div>
    </div>
  );
}
