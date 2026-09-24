import { ALL_STAFF, requireRole } from "@/lib/auth";
import { CustomersScreen } from "./customers-screen";

export default async function CustomersPage() {
  await requireRole(ALL_STAFF);
  return <CustomersScreen />;
}
