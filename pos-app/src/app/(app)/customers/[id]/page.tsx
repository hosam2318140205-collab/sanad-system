import { ALL_STAFF, requireRole } from "@/lib/auth";
import { CustomerProfile } from "./customer-profile";

export default async function CustomerProfilePage({ params }: PageProps<"/customers/[id]">) {
  await requireRole(ALL_STAFF);
  const { id } = await params;
  return <CustomerProfile id={id} />;
}
