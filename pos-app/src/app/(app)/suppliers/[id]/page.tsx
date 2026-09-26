import { MANAGERS, requireRole } from "@/lib/auth";
import { SupplierProfile } from "./supplier-profile";

export default async function SupplierPage(props: PageProps<"/suppliers/[id]">) {
  await requireRole(MANAGERS);
  const { id } = await props.params;
  return <SupplierProfile id={id} />;
}
