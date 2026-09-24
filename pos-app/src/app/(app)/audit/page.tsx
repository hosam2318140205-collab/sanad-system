import { OWNER_ONLY, requireRole } from "@/lib/auth";
import { AuditScreen } from "./audit-screen";

export default async function AuditPage() {
  await requireRole(OWNER_ONLY);
  return <AuditScreen />;
}
