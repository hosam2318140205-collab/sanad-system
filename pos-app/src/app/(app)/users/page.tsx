import { OWNER_ONLY, requireRole } from "@/lib/auth";
import { UsersScreen } from "./users-screen";

export default async function UsersPage() {
  await requireRole(OWNER_ONLY);
  return <UsersScreen />;
}
