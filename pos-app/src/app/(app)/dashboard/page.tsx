import { MANAGERS, requireRole } from "@/lib/auth";
import { Dashboard } from "./dashboard";

export default async function DashboardPage() {
  await requireRole(MANAGERS);
  return <Dashboard />;
}
