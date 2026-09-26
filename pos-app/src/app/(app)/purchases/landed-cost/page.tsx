import { MANAGERS, requireRole } from "@/lib/auth";
import { LandedCostScreen } from "./landed-cost-screen";

export default async function LandedCostPage() {
  await requireRole(MANAGERS);
  return <LandedCostScreen />;
}
