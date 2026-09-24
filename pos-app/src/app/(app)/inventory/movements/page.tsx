import { MANAGERS, requireRole } from "@/lib/auth";
import { MovementsScreen } from "./movements-screen";

export default async function MovementsPage() {
  await requireRole(MANAGERS);
  return <MovementsScreen />;
}
