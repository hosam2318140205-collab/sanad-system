import { Suspense } from "react";
import { Loading } from "@/components/ui";
import { ALL_STAFF, requireRole } from "@/lib/auth";
import { PosScreen } from "./pos-screen";

export default async function PosPage() {
  await requireRole(ALL_STAFF);
  return (
    <Suspense fallback={<Loading />}>
      <PosScreen />
    </Suspense>
  );
}
