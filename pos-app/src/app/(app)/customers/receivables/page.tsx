import { MANAGERS, requireRole } from "@/lib/auth";
import { ReceivablesScreen } from "./receivables-screen";

export default async function ReceivablesPage() {
  await requireRole(MANAGERS);
  return <ReceivablesScreen />;
}
