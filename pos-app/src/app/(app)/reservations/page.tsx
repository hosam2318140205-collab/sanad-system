import { ALL_STAFF, requireRole } from "@/lib/auth";
import { ReservationsScreen } from "./reservations-screen";

export default async function ReservationsPage() {
  await requireRole(ALL_STAFF);
  return <ReservationsScreen />;
}
