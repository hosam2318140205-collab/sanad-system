import { ALL_STAFF, requireRole } from "@/lib/auth";
import { CountsList } from "./counts-list";

export default async function CountsPage() {
  await requireRole(ALL_STAFF);
  return <CountsList />;
}
