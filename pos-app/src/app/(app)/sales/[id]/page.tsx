import { ALL_STAFF, requireRole } from "@/lib/auth";
import { SaleDetail } from "./sale-detail";

export default async function SaleDetailPage(props: PageProps<"/sales/[id]">) {
  await requireRole(ALL_STAFF);
  const { id } = await props.params;
  return <SaleDetail id={id} />;
}
