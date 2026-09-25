import { MANAGERS, requireRole } from "@/lib/auth";
import { AdvisorScreen } from "./advisor-screen";

export default async function AdvisorPage() {
  await requireRole(MANAGERS);
  return <AdvisorScreen />;
}
