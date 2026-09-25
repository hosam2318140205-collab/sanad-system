import { MANAGERS, requireRole } from "@/lib/auth";
import { ExpensesScreen } from "./expenses-screen";

export default async function ExpensesPage() {
  await requireRole(MANAGERS);
  return <ExpensesScreen />;
}
