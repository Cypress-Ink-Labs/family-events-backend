# Plan 015: Foundational migrations have paired rollback scripts

> **Executor instructions**: This is a HIGH-RISK, careful plan. Do **one migration at a time**, never
> bundle it with a behavior change, and treat every uncertainty as a STOP. Update this plan's row in
> `plans/README.md` when done (or partially done — record which timestamps were backfilled).
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/migrations supabase/rollbacks tests/guards/migration-rollbacks.test.mjs`

## Status

- **Priority**: P3
- **Effort**: L (multi-day; can be done incrementally, a few migrations at a time)
- **Risk**: HIGH (a wrong rollback that silently leaves objects/data is worse than no rollback; these are
  the schema's foundation)
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

The repo's policy (enforced by `tests/guards/migration-rollbacks.test.mjs`) is that every migration ships
a paired `supabase/rollbacks/<timestamp>_*_down.sql`. **18 foundational migrations are grandfathered** in a
`LEGACY_ALLOWLIST` — they predate the rule and have no rollback, including the 227 KB
`20260601000000_schema_baseline.sql`. If one of these needs to be reverted in production, there is no
tested down-path, so recovery is manual and error-prone on exactly the riskiest objects. This plan shrinks
the allowlist by backfilling rollbacks, highest-value first.

## Current state

`tests/guards/migration-rollbacks.test.mjs:19-38` — the allowlist (18 timestamps):

```
20260601000001 20260601001000 20260601002000 20260601003000 20260601004000 20260601005000
20260601006000 20260601007000 20260601008000 20260601009000 20260601010000 20260601011000
20260601011001 20260601012000 20260601013000 20260601014000 20260601015000 20260601016000
```

The test has two parts: (1) every migration has a rollback **or** is in the allowlist; (2) every allowlist
entry still lacks a rollback (so once you add a rollback you MUST remove its timestamp from the allowlist,
or the test fails). Existing rollbacks in `supabase/rollbacks/` (27 files) are the style reference — e.g.
`20260601032000_drop_old_search_events_overload_down.sql` shows the conventions: a `BEGIN; … COMMIT;`
block, comments citing the exact UP migration + line range the body was copied from, and explicit notes
about ordering hazards.

Note `20260601000000` (the baseline) is **not** in the allowlist but **does** have a rollback
(`20260601000000_001_schema_down.sql`). So the 18 allowlisted ones are the real gap.

## Approach — incremental, value-ordered

Do NOT attempt all 18 at once. Order by likelihood-of-needing-revert × tractability. Suggested batches:

1. **Smaller, self-contained ones first** (data/seed/toggle migrations): `20260601007000`,
   `20260601008000`, `20260601009000`, `20260601010000`, `20260601011000`, `20260601011001`,
   `20260601012000`–`20260601016000` (invite-gate + anon-access + provider tweaks). These are mostly
   policy/seed/config changes with clear inverses.
2. **Medium structural** ones: `20260601005000`, `20260601001000`.
3. **Large foundational** ones last and most carefully: `20260601002000`, `20260601003000`,
   `20260601004000`, `20260601006000`, `20260601000001`.

## Steps (repeat per migration)

### Step A: Read the UP migration fully

Open `supabase/migrations/<ts>_*.sql`. Enumerate every object/effect it creates or changes: `CREATE TABLE`,
`ALTER TABLE`, `CREATE FUNCTION`, `CREATE POLICY`, `CREATE INDEX`, `GRANT`/`REVOKE`, `INSERT` (seed data),
enum additions, trigger creation, materialized views.

### Step B: Write the inverse, in reverse dependency order

Create `supabase/rollbacks/<ts>_<slug>_down.sql`:

- `BEGIN; … COMMIT;`.
- Drop/restore in the reverse order of creation (drop dependents before dependencies).
- For `CREATE OR REPLACE FUNCTION`, the inverse is to restore the **previous** definition if one existed,
  or `DROP FUNCTION` if the UP introduced it. Cite the source of any restored body in a comment (as the
  existing rollbacks do).
- For seed `INSERT`s, `DELETE` exactly those rows (by stable key), not a blanket delete.
- For enum value additions: Postgres can't drop an enum value — document this as irreversible in the
  rollback header and revert only what's safely revertible (this is a known hard case; a STOP if the
  migration's core effect is an un-droppable enum value).
- Header comment must note any ordering hazard (see the `032000` rollback for the pattern).

### Step C: Remove the timestamp from `LEGACY_ALLOWLIST`

Delete that entry from `tests/guards/migration-rollbacks.test.mjs`. The guard test's part (2) **requires**
this — leaving it in fails the build now that a rollback exists.

### Step D: Verify the rollback actually reverses, against a local DB

This is the real test — a rollback that parses but doesn't reverse is the failure mode this plan exists to
prevent.

- `pnpm run db:start` (local Supabase).
- Confirm the migration's objects exist (query `pg_proc`/`pg_policies`/`information_schema`).
- Run the rollback: `psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/rollbacks/<ts>_*_down.sql`.
- Confirm the objects are gone / restored (re-query).
- Re-apply the UP migration (or `pnpm run db:reset` equivalent) so the DB returns to head — the rollback
  must not leave the DB unmigratable.

## Commands you will need

| Purpose          | Command                                                                                              | Expected                                                         |
| ---------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Guard test       | `pnpm run workspace:test`                                                                            | migration-rollbacks test passes (pairing + allowlist consistent) |
| Local DB         | `pnpm run db:start` / `pnpm run db:stop`                                                             | Supabase up/down                                                 |
| Apply a SQL file | `psql "$DB_URL" -v ON_ERROR_STOP=1 -f <file>`                                                        | exit 0                                                           |
| Inspect objects  | `psql "$DB_URL" -c "\df+ <schema>.*"`, `\d <table>`, `select * from pg_policies where tablename='…'` | confirm before/after                                             |

## Done criteria (per migration backfilled)

- [ ] `supabase/rollbacks/<ts>_*_down.sql` exists and parses
- [ ] The migration's objects verified present, then absent/restored after running the rollback against a local DB
- [ ] UP re-applies cleanly afterward (DB returns to head)
- [ ] The `<ts>` removed from `LEGACY_ALLOWLIST`
- [ ] `pnpm run workspace:test` passes
- [ ] `plans/README.md` row for 015 updated with which timestamps are now covered (this plan may land in pieces)

## STOP conditions

Stop and report (do not guess) if:

- A migration's effect is genuinely irreversible (dropped column with data, added enum value that other
  rows now use) — document the irreversibility in the rollback header, revert what's safe, and flag the
  rest. Do NOT fabricate a lossy "rollback" that pretends to restore data.
- You cannot determine the **previous** definition of a `CREATE OR REPLACE`d function (no earlier
  migration defines it) — report; restoring a wrong body is dangerous.
- The local-DB verification (Step D) shows the rollback doesn't fully reverse — fix or STOP; never commit
  an unverified rollback for a foundational migration.

## Maintenance notes

- This is the one plan where partial completion is expected and fine — record progress in the README row.
- Reviewer: for each rollback, the question is "does this actually return the schema to its pre-migration
  state?" Verify against the local-DB evidence, not just that the SQL parses.
- Do not bundle this with any feature/behavior migration — keep rollback backfill commits isolated.
