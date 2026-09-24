"use server";

import { getCurrentProfile } from "@/lib/auth";
import { createServiceSupabase } from "@/lib/supabase/server";
import type { UserRole } from "@/lib/types";

type Result = { ok: true } | { ok: false; error: string };

const ROLES: UserRole[] = ["owner", "manager", "cashier"];

async function requireOwner(): Promise<Result | null> {
  const me = await getCurrentProfile();
  if (!me || !me.is_active || me.role !== "owner") return { ok: false, error: "هذه العملية للمالك فقط" };
  return null;
}

export async function createStaffUser(input: {
  full_name: string;
  email: string;
  password: string;
  role: UserRole;
}): Promise<Result> {
  const denied = await requireOwner();
  if (denied) return denied;

  const admin = createServiceSupabase();
  if (!admin) return { ok: false, error: "أضف SUPABASE_SERVICE_ROLE_KEY في متغيرات البيئة لإنشاء المستخدمين" };
  if (!ROLES.includes(input.role)) return { ok: false, error: "صلاحية غير صحيحة" };
  if (!input.email.trim() || input.password.length < 8) {
    return { ok: false, error: "البريد مطلوب وكلمة المرور 8 أحرف على الأقل" };
  }

  const { error } = await admin.auth.admin.createUser({
    email: input.email.trim().toLowerCase(),
    password: input.password,
    email_confirm: true,
    user_metadata: { full_name: input.full_name.trim() },
    // app_metadata لا يمكن للمستخدم تعديله — trigger قاعدة البيانات يقرأ الدور منه
    app_metadata: { role: input.role },
  });
  if (error) {
    return { ok: false, error: error.message.includes("already") ? "البريد مسجل مسبقاً" : error.message };
  }
  return { ok: true };
}

export async function resetStaffPassword(userId: string, password: string): Promise<Result> {
  const denied = await requireOwner();
  if (denied) return denied;
  const admin = createServiceSupabase();
  if (!admin) return { ok: false, error: "أضف SUPABASE_SERVICE_ROLE_KEY في متغيرات البيئة" };
  if (password.length < 8) return { ok: false, error: "كلمة المرور 8 أحرف على الأقل" };
  const { error } = await admin.auth.admin.updateUserById(userId, { password });
  return error ? { ok: false, error: error.message } : { ok: true };
}
