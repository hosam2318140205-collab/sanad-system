import { MANAGERS, requireRole } from "@/lib/auth";
import { DecisionCenter } from "./decision-center";

export default async function DecisionsPage() {
  await requireRole(MANAGERS);
  return <DecisionCenter />;
}
