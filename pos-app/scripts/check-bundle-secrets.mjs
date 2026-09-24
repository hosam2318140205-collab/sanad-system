// Fails if anything secret made it into the browser bundles (.next/static).
// Run after `next build`. Checks: the actual service key value (if set in the environment),
// any JWT whose role is service_role, new-format sb_secret_ keys, and the env var name itself.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = join(process.cwd(), ".next", "static");
// On Vercel the key is in process.env; locally it may only be in .env.local / .env.production.local
function fromEnvFiles(name) {
  for (const f of [".env.production.local", ".env.local", ".env.production", ".env"]) {
    if (!existsSync(f)) continue;
    const line = readFileSync(f, "utf8").split(/\r?\n/).find((l) => l.startsWith(name + "="));
    if (line) return line.slice(name.length + 1).trim().replace(/^["']|["']$/g, "");
  }
  return "";
}
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || fromEnvFiles("SUPABASE_SERVICE_ROLE_KEY");
if (!serviceKey) console.warn("! SUPABASE_SERVICE_ROLE_KEY not set — checking patterns only");
const files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else if (/\.(js|json|html|txt|map)$/.test(name)) files.push(p);
  }
})(root);

const jwtRe = /eyJ[A-Za-z0-9_-]{10,}\.(eyJ[A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]{10,}/g;
const problems = [];
for (const f of files) {
  const text = readFileSync(f, "utf8");
  if (serviceKey && text.includes(serviceKey)) problems.push(`${f}: contains SUPABASE_SERVICE_ROLE_KEY value`);
  if (/sb_secret_[A-Za-z0-9_-]{16,}/.test(text)) problems.push(`${f}: contains an sb_secret_ key`);
  if (text.includes("SUPABASE_SERVICE_ROLE_KEY")) problems.push(`${f}: references SUPABASE_SERVICE_ROLE_KEY`);
  for (const m of text.matchAll(jwtRe)) {
    try {
      const payload = JSON.parse(Buffer.from(m[1], "base64url").toString());
      if (payload.role === "service_role") problems.push(`${f}: contains a service_role JWT`);
    } catch {
      /* not a JWT */
    }
  }
}

if (problems.length) {
  console.error("✗ Secrets found in client bundles:\n" + problems.join("\n"));
  process.exit(1);
}
console.log(`✓ No secrets in ${files.length} client files`);
