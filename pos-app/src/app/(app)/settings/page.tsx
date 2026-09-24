import { OWNER_ONLY, requireRole } from "@/lib/auth";
import { SettingsScreen } from "./settings-screen";

export default async function SettingsPage() {
  await requireRole(OWNER_ONLY);
  return <SettingsScreen />;
}
