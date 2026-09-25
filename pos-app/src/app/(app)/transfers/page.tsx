import { ALL_STAFF, requireRole } from "@/lib/auth";
import { TransfersList } from "./transfers-list";

export default async function TransfersPage() {
  await requireRole(ALL_STAFF);
  return <TransfersList />;
}
