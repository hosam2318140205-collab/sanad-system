import "server-only";
import { redirect } from "next/navigation";
import { cache } from "react";
import { createServerSupabase } from "./supabase/server";
import type { Profile, UserRole } from "./types";

export const getCurrentProfile = cache(async (): Promise<Profile | null> => {
  const supabase = await createServerSupabase();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = claims?.claims?.sub;
  if (!userId) return null;
  const { data } = await supabase
    .from("profiles")
    .select("id, full_name, email, phone, role, is_active, created_at")
    .eq("id", userId)
    .maybeSingle();
  return (data as Profile | null) ?? null;
});

/** Server-side guard for pages. Redirects when the user lacks one of the roles. */
export async function requireRole(roles: UserRole[]): Promise<Profile> {
  const profile = await getCurrentProfile();
  if (!profile) redirect("/login");
  if (!profile.is_active) redirect("/pending");
  if (!roles.includes(profile.role)) redirect(profile.role === "cashier" ? "/pos" : "/dashboard");
  return profile;
}

export const MANAGERS: UserRole[] = ["owner", "manager"];
export const ALL_STAFF: UserRole[] = ["owner", "manager", "cashier"];
export const OWNER_ONLY: UserRole[] = ["owner"];
