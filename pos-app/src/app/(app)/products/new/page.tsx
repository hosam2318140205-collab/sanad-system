import { MANAGERS, requireRole } from "@/lib/auth";
import { ProductForm } from "../product-form";

export default async function NewProductPage() {
  await requireRole(MANAGERS);
  return <ProductForm productId={null} />;
}
