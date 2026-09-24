import { Suspense } from "react";
import { Loading } from "@/components/ui";
import { ALL_STAFF, requireRole } from "@/lib/auth";
import { ReturnsScreen } from "./returns-screen";

export default async function ReturnsPage() {
  await requireRole(ALL_STAFF);
  return (
    <Suspense fallback={<Loading />}>
      <ReturnsScreen />
    </Suspense>
  );
}
