import { ALL_STAFF, requireRole } from "@/lib/auth";
import { TransferDetail } from "./transfer-detail";

export default async function TransferPage(props: PageProps<"/transfers/[id]">) {
  await requireRole(ALL_STAFF);
  const { id } = await props.params;
  return <TransferDetail id={id} />;
}
