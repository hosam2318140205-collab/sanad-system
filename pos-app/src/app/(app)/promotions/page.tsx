import { MANAGERS, requireRole } from "@/lib/auth";
import { PromotionsScreen } from "./promotions-screen";

export default async function PromotionsPage() {
  await requireRole(MANAGERS);
  return <PromotionsScreen />;
}
