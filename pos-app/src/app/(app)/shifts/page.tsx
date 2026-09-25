import { ALL_STAFF, requireRole } from "@/lib/auth";
import { ShiftsScreen } from "./shifts-screen";

export default async function ShiftsPage() {
  await requireRole(ALL_STAFF);
  return <ShiftsScreen />;
}
