import { redirect } from "next/navigation";
import { AppShell } from "@/components/app-shell";
import { getCurrentProfile } from "@/lib/auth";
import { createServerSupabase } from "@/lib/supabase/server";
import type { StoreSettings } from "@/lib/types";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const profile = await getCurrentProfile();
  if (!profile) redirect("/login");
  if (!profile.is_active) redirect("/pending");

  const supabase = await createServerSupabase();
  const { data: settings } = await supabase.from("store_settings").select("*").eq("id", 1).single();
  if (!settings) redirect("/setup");

  return (
    <AppShell profile={profile} settings={settings as StoreSettings}>
      {children}
    </AppShell>
  );
}
