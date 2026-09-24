import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";

export default async function Home() {
  const profile = await getCurrentProfile();
  redirect(profile?.role === "cashier" ? "/pos" : "/dashboard");
}
