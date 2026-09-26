import { MANAGERS, requireRole } from "@/lib/auth";
import { InvoiceEditor } from "../invoice-editor";

export default async function InvoicePage(props: PageProps<"/purchases/invoices/[id]">) {
  await requireRole(MANAGERS);
  const { id } = await props.params;
  return <InvoiceEditor id={id} poId={null} supplierId={null} />;
}
