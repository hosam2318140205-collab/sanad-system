// Concatenates supabase/migrations/*.sql (in order) into one file that can be pasted
// into the Supabase SQL Editor. `--check` fails when the bundle is out of date.
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const dir = join(process.cwd(), "supabase", "migrations");
const out = join(process.cwd(), "supabase", "setup", "01_all_migrations.sql");
const files = readdirSync(dir).filter((f) => /^\d+_.*\.sql$/.test(f)).sort();

const header = `-- ملف مُولَّد تلقائياً من supabase/migrations — لا تعدّله يدوياً (npm run db:bundle)
-- نفّذه مرة واحدة فقط على مشروع Supabase جديد، في SQL Editor.
-- يحتوي: ${files.join(", ")}
`;
const body = files
  .map((f) => `\n-- ${"=".repeat(69)}\n-- ${f}\n-- ${"=".repeat(69)}\n${readFileSync(join(dir, f), "utf8").trimEnd()}\n`)
  .join("");
const content = header + "\nbegin;\n" + body + "\ncommit;\n";

if (process.argv.includes("--check")) {
  if (!existsSync(out) || readFileSync(out, "utf8") !== content) {
    console.error("✗ supabase/setup/01_all_migrations.sql is out of date — run: npm run db:bundle");
    process.exit(1);
  }
  console.log(`✓ Migration bundle is up to date (${files.length} files)`);
} else {
  writeFileSync(out, content);
  console.log(`Wrote ${out} (${files.length} migrations)`);
}
