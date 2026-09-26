import { MANAGERS, requireRole } from "@/lib/auth";
import { CustomerAnalyticsScreen } from "./analytics-screen";

export default async function CustomerAnalyticsPage() {
  await requireRole(MANAGERS);
  return <CustomerAnalyticsScreen />;
}
