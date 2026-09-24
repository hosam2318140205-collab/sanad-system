import { MANAGERS, requireRole } from "@/lib/auth";
import { Reports } from "./reports";

export default async function ReportsPage() {
  await requireRole(MANAGERS);
  return <Reports />;
}
