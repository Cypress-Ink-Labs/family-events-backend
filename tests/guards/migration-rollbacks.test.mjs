import { strict as assert } from "node:assert";
import { readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

// Every Supabase migration must ship a paired rollback script in
// supabase/rollbacks/ named `<timestamp>_*_down.sql` (timestamp-prefix match;
// legacy rollbacks use numbered segments like `001_schema_down`).
//
// LEGACY_ALLOWLIST grandfathers migrations that predate this rule. Do not add
// new timestamps here — write a rollback instead. Shrink this list as legacy
// rollbacks are backfilled.

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);
const migrationsDir = path.join(repoRoot, "supabase", "migrations");
const rollbacksDir = path.join(repoRoot, "supabase", "rollbacks");

const LEGACY_ALLOWLIST = new Set([
  // Backfilled rollbacks land in supabase/rollbacks/ and are removed from this list.
  // Done (plan 015, batch 1): 000001, 007000, 010000, 016000.
  // Done (plan 015, batch 2): 001000, 002000, 003000, 004000, 005000, 006000,
  //   008000, 009000, 011000, 011001, 012000, 013000, 014000, 015000.
  // All grandfathered migrations now ship DB-verified rollbacks — allowlist is empty.
]);

function timestampOf(filename) {
  const match = /^(\d{14})_/.exec(filename);
  return match ? match[1] : null;
}

test("every migration has a rollback script (or is grandfathered)", () => {
  const migrations = readdirSync(migrationsDir).filter((f) =>
    f.endsWith(".sql"),
  );
  assert.ok(migrations.length > 0, "no migrations found — wrong path?");

  const rollbackTimestamps = new Set(
    readdirSync(rollbacksDir)
      .filter((f) => f.endsWith("_down.sql"))
      .map(timestampOf)
      .filter(Boolean),
  );

  const missing = migrations.filter((f) => {
    const ts = timestampOf(f);
    assert.ok(ts, `migration ${f} does not start with a 14-digit timestamp`);
    return !rollbackTimestamps.has(ts) && !LEGACY_ALLOWLIST.has(ts);
  });

  assert.deepEqual(
    missing,
    [],
    `migrations missing a supabase/rollbacks/<timestamp>_*_down.sql file:\n  ${missing.join("\n  ")}`,
  );
});

test("legacy allowlist only contains migrations that still lack rollbacks", () => {
  const migrationTimestamps = new Set(
    readdirSync(migrationsDir).map(timestampOf).filter(Boolean),
  );
  const rollbackTimestamps = new Set(
    readdirSync(rollbacksDir)
      .filter((f) => f.endsWith("_down.sql"))
      .map(timestampOf)
      .filter(Boolean),
  );

  for (const ts of LEGACY_ALLOWLIST) {
    assert.ok(
      migrationTimestamps.has(ts),
      `allowlist entry ${ts} matches no migration — remove it`,
    );
    assert.ok(
      !rollbackTimestamps.has(ts),
      `allowlist entry ${ts} now has a rollback — remove it`,
    );
  }
});
