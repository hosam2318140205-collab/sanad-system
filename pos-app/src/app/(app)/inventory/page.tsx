import { MANAGERS, requireRole } from "@/lib/auth";
import { InventoryScreen } from "./inventory-screen";

export default async function InventoryPage() {
  await requireRole(MANAGERS);
  return <InventoryScreen />;
}
