import { MANAGERS, requireRole } from "@/lib/auth";
import { PayablesDashboard } from "./payables-dashboard";

export default async function PayablesPage() {
  await requireRole(MANAGERS);
  return <PayablesDashboard />;
}
