import { MANAGERS, requireRole } from "@/lib/auth";
import { InvoiceEditor } from "../invoice-editor";

export default async function NewInvoicePage(props: PageProps<"/purchases/invoices/new">) {
  await requireRole(MANAGERS);
  const sp = await props.searchParams;
  const po = typeof sp.po === "string" ? sp.po : null;
  const supplier = typeof sp.supplier === "string" ? sp.supplier : null;
  return <InvoiceEditor id={null} poId={po} supplierId={supplier} />;
}
