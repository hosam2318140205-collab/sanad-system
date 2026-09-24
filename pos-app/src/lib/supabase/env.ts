export const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
export const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

export const isSupabaseConfigured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);

/**
 * NEXT_PUBLIC_* values are shipped to every browser. Refuse to run with a secret key there:
 * legacy service_role JWTs and new-format sb_secret_ keys both bypass RLS.
 */
export function isSecretSupabaseKey(key: string): boolean {
  if (key.startsWith("sb_secret_")) return true;
  const payload = key.split(".")[1];
  if (!payload) return false;
  try {
    const json = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/")));
    return json?.role === "service_role";
  } catch {
    return false;
  }
}

if (isSecretSupabaseKey(SUPABASE_ANON_KEY)) {
  throw new Error(
    "NEXT_PUBLIC_SUPABASE_ANON_KEY contains a secret (service_role / sb_secret_) key. " +
      "Use the anon / publishable key here; the secret key belongs only in the server-only service role variable.",
  );
}
