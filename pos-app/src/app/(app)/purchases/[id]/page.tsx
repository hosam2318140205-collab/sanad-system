import { MANAGERS, requireRole } from "@/lib/auth";
import { PurchaseForm } from "../purchase-form";

export default async function PurchasePage(props: PageProps<"/purchases/[id]">) {
  await requireRole(MANAGERS);
  const { id } = await props.params;
  return <PurchaseForm id={id} />;
}
