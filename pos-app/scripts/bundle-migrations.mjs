// Concatenates supabase/migrations/*.sql (in order) into one file that can be pasted
// into the Supabase SQL Editor for a NEW project, and writes one upgrade file per migration
// added after the first production release (for projects that already ran the bundle).
// `--check` fails when any generated file is out of date.
import { readdirSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
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

// Migrations up to this number shipped in the first production bundle.
const BASELINE = 5;
const upgradesDir = join(process.cwd(), "supabase", "setup", "upgrades");
const outputs = new Map([[out, content]]);
for (const f of files.filter((f) => Number(f.split("_")[0]) > BASELINE)) {
  outputs.set(
    join(upgradesDir, f),
    `-- ترقية مشروع قائم: نفّذ هذا الملف مرة واحدة في SQL Editor (مولَّد من supabase/migrations/${f})
-- لا تنفذه على مشروع جديد — المشروع الجديد يستخدم 01_all_migrations.sql الذي يتضمنه.
begin;
${readFileSync(join(dir, f), "utf8").trimEnd()}
commit;
`,
  );
}

if (process.argv.includes("--check")) {
  const stale = [...outputs].filter(([p, c]) => !existsSync(p) || readFileSync(p, "utf8") !== c).map(([p]) => p);
  if (stale.length) {
    console.error("✗ Generated SQL is out of date — run: npm run db:bundle\n" + stale.join("\n"));
    process.exit(1);
  }
  console.log(`✓ Migration bundle is up to date (${files.length} files, ${outputs.size - 1} upgrades)`);
} else {
  mkdirSync(upgradesDir, { recursive: true });
  for (const [p, c] of outputs) writeFileSync(p, c);
  console.log(`Wrote bundle (${files.length} migrations) and ${outputs.size - 1} upgrade file(s)`);
}
