import { MANAGERS, requireRole } from "@/lib/auth";
import { InvoicesList } from "./invoices-list";

export default async function InvoicesPage() {
  await requireRole(MANAGERS);
  return <InvoicesList />;
}
