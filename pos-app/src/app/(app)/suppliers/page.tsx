import { MANAGERS, requireRole } from "@/lib/auth";
import { SuppliersScreen } from "./suppliers-screen";

export default async function SuppliersPage() {
  await requireRole(MANAGERS);
  return <SuppliersScreen />;
}
