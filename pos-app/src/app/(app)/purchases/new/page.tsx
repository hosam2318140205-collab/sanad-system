import { MANAGERS, requireRole } from "@/lib/auth";
import { PurchaseForm } from "../purchase-form";

export default async function NewPurchasePage() {
  await requireRole(MANAGERS);
  return <PurchaseForm id={null} />;
}
