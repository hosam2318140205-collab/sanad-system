import { MANAGERS, requireRole } from "@/lib/auth";
import { ProductForm } from "../product-form";

export default async function EditProductPage(props: PageProps<"/products/[id]">) {
  await requireRole(MANAGERS);
  const { id } = await props.params;
  return <ProductForm productId={id} />;
}
