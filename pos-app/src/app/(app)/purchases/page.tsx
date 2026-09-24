import { MANAGERS, requireRole } from "@/lib/auth";
import { PurchasesList } from "./purchases-list";

export default async function PurchasesPage() {
  await requireRole(MANAGERS);
  return <PurchasesList />;
}
