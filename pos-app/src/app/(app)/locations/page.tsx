import { OWNER_ONLY, requireRole } from "@/lib/auth";
import { LocationsScreen } from "./locations-screen";

export default async function LocationsPage() {
  await requireRole(OWNER_ONLY);
  return <LocationsScreen />;
}
