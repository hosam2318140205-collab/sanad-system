import { ALL_STAFF, requireRole } from "@/lib/auth";
import { SalesList } from "./sales-list";

export default async function SalesPage() {
  await requireRole(ALL_STAFF);
  return <SalesList />;
}
