import { ALL_STAFF, requireRole } from "@/lib/auth";
import { CountSheet } from "./count-sheet";

export default async function CountPage(props: PageProps<"/inventory/counts/[id]">) {
  await requireRole(ALL_STAFF);
  const { id } = await props.params;
  return <CountSheet id={id} />;
}
