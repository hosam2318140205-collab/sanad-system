import { MANAGERS, requireRole } from "@/lib/auth";
import { InsightsScreen } from "./insights-screen";

export default async function InsightsPage() {
  await requireRole(MANAGERS);
  return <InsightsScreen />;
}
