import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const repoRoot = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "..",
);
const sharedPath = path.join(
  repoRoot,
  "packages",
  "shared",
  "src",
  "url-validation.ts",
);
const edgePath = path.join(
  repoRoot,
  "supabase",
  "functions",
  "_shared",
  "url-validation.ts",
);

const sharedSource = readFileSync(sharedPath, "utf8");
const edgeSource = readFileSync(edgePath, "utf8");

if (process.argv.includes("--check")) {
  if (sharedSource !== edgeSource) {
    console.error(
      "Supabase URL validator is out of sync with packages/shared/src/url-validation.ts",
    );
    process.exit(1);
  }
  process.exit(0);
}

if (sharedSource !== edgeSource) {
  writeFileSync(edgePath, sharedSource);
}
