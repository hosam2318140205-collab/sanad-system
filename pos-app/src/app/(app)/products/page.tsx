import { MANAGERS, requireRole } from "@/lib/auth";
import { ProductsList } from "./products-list";

export default async function ProductsPage() {
  await requireRole(MANAGERS);
  return <ProductsList />;
}
