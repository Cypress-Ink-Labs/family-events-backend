# Plan 024: Make `public.find_similar_events_by_id` SECURITY DEFINER (unblock anon callers)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> "STOP conditions" item occurs, stop and report. When done, update the status
> row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5daa274..HEAD -- supabase/migrations supabase/rollbacks supabase/docs/SEMANTIC_SEARCH.md`
> Also confirm the current definition with:
> `grep -n "SECURITY INVOKER\|SECURITY DEFINER" supabase/migrations/20260601029000_find_similar_events_by_id.sql`
> If the public wrapper is no longer `SECURITY INVOKER`, treat it as a STOP condition (already fixed).

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (unblocks plan 028's `/{id}/similar` endpoint)
- **Category**: bug
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

The public semantic-search wrapper `public.find_similar_events_by_id` is
`SECURITY INVOKER`. When `anon` (or `authenticated`) calls it via PostgREST, the
wrapper runs as the caller, then tries to invoke the `private` body the caller
has no `EXECUTE` on, so the call fails with `42501 permission denied`. This is
documented in `supabase/docs/SEMANTIC_SEARCH.md:71-104` and blocks any
client-side / public "similar events" feature (including the designed
`GET /events/{id}/similar` endpoint). The fix is the same pattern already used
by `private.invites_required`: make the public wrapper `SECURITY DEFINER`.

## Current state

- `supabase/migrations/20260601029000_find_similar_events_by_id.sql` defines the
  function chain: `public.find_similar_events_by_id` (SECURITY INVOKER, wrapper) →
  `private.find_similar_events_by_id` (SECURITY DEFINER) → `private.find_similar_events`
  (SECURITY DEFINER). (Confirmed via `SEMANTIC_SEARCH.md:48-50`.)
- Fix, verbatim from `SEMANTIC_SEARCH.md:87-104`:

  ```sql
  CREATE OR REPLACE FUNCTION public.find_similar_events_by_id(...)
  RETURNS TABLE (...)
  LANGUAGE sql
  SECURITY DEFINER        -- change from INVOKER
  SET search_path TO ''
  AS $$
    SELECT * FROM private.find_similar_events_by_id(p_event_id, p_limit, p_city_id);
  $$;
  REVOKE EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid) FROM PUBLIC;
  GRANT EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid)
    TO authenticated, anon, service_role;
  ```
  **Use the EXACT signature (arg names, types, RETURNS TABLE columns) from the
  original migration `20260601029000_*.sql` — copy it; do not paraphrase.**
  `SET search_path TO ''` is mandatory for SECURITY DEFINER safety (forces
  schema-qualified names; the body already qualifies `private.`).

### Repo migration conventions (CLAUDE.md)

- Migrations are **append-only** — never edit `20260601029000_*.sql`. Add a NEW
  migration with a timestamp greater than the current max in `supabase/migrations/`.
- **Every new migration needs a paired rollback** in `supabase/rollbacks/` named
  `<same-timestamp>_<name>_down.sql`; the guard
  `tests/guards/migration-rollbacks.test.mjs` fails if it is missing. The rollback
  here restores the wrapper to `SECURITY INVOKER` with the original grants.
- Naming: `<timestamp>_<snake_name>.sql` (see existing files for the timestamp format).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Rollback-pairing guard | `pnpm run workspace:test` | all pass (incl migration-rollbacks) |
| Lint | `pnpm run lint` | exit 0 |
| DB apply + integration (needs local Supabase) | `pnpm run db:test` | pass — best effort |
| Security advisors (linked DB) | `pnpm run db:advisors:security` | no new errors — best effort |

If a local Supabase is not available to you, the hard gates are
`pnpm run workspace:test` (rollback pairing) + lint; mark the DB-apply
verification as "not run — needs local Supabase" and STOP if you cannot confirm
the SQL applies, rather than guessing.

## Scope

**In scope** (create):
- `supabase/migrations/<new-timestamp>_find_similar_events_by_id_security_definer.sql`
- `supabase/rollbacks/<new-timestamp>_find_similar_events_by_id_security_definer_down.sql`
- `supabase/docs/SEMANTIC_SEARCH.md` — flip the "Known issue: anon callers blocked"
  section to resolved (note the migration that fixed it). Keep the rest intact.

**Out of scope**:
- Editing the original `20260601029000_*.sql` (append-only).
- The `private.*` function bodies — only the `public` wrapper's SECURITY mode +
  grants change. (Exception: the OPTIONAL `p_limit` clamp in Step 4.)
- `packages/contracts/src/database.types.ts` (regenerate only if `pnpm run db:types`
  is part of the normal flow and the signature is unchanged — it is unchanged here,
  so leave it).

## Git workflow

- Branch: `advisor/024-semantic-search-security-definer`
- Conventional Commits, e.g. `fix(db): make find_similar_events_by_id wrapper SECURITY DEFINER`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Read the original definition
Open `supabase/migrations/20260601029000_find_similar_events_by_id.sql` and copy
the EXACT `public.find_similar_events_by_id` signature (arg names/types + the full
`RETURNS TABLE (...)` column list) and its body.
**Verify**: you have the exact signature. No command.

### Step 2: Write the forward migration
New file with a timestamp > current max. `CREATE OR REPLACE FUNCTION
public.find_similar_events_by_id(<exact sig>) ... LANGUAGE sql SECURITY DEFINER
SET search_path TO '' AS $$ SELECT * FROM private.find_similar_events_by_id(...) $$;`
then the REVOKE + GRANT block (exact arg types in the function reference).
**Verify**: `grep -n "SECURITY DEFINER" <new migration>` shows the wrapper.

### Step 3: Write the paired rollback
`supabase/rollbacks/<same-timestamp>_..._down.sql` that `CREATE OR REPLACE`s the
wrapper back to `SECURITY INVOKER` with the original grants (restore the pre-fix
state). Add a header comment noting it reintroduces the known anon-block.
**Verify**: `pnpm run workspace:test` → migration-rollbacks guard passes.

### Step 4 (OPTIONAL — defense in depth): clamp `p_limit`
`SEMANTIC_SEARCH.md:111-118` notes `p_limit` is unbounded. If and only if you can
verify it via local DB, add `LEAST(p_limit, 50)` inside `private.find_similar_events_by_id`
in the SAME migration (+ mirror in the rollback). If you cannot DB-verify, SKIP
this step and leave a one-line note in the doc — do not ship an unverified body change.

### Step 5: Update the doc + gates
Mark the "anon callers blocked" section resolved (reference the new migration).
**Verify**: `pnpm run lint` → 0; `pnpm run workspace:test` → pass; if local Supabase available, `pnpm run db:test` → pass and confirm an `anon` PostgREST call to `find_similar_events_by_id` no longer returns `42501`.

## Test plan

- The rollback-pairing guard (`migration-rollbacks.test.mjs`) is the structural
  gate — it must pass. If local Supabase is available, add/confirm an integration
  check (db:test) that an `anon`-role call succeeds; otherwise document it as
  pending manual verification on deploy.
- Verification: `pnpm run workspace:test` passes; `db:test` passes where runnable.

## Done criteria

- [ ] New forward migration sets the `public` wrapper to `SECURITY DEFINER` + `SET search_path TO ''` + re-grants to `authenticated, anon, service_role`, using the exact original signature
- [ ] Paired `_down.sql` exists and restores SECURITY INVOKER + original grants
- [ ] `pnpm run workspace:test` passes (migration-rollbacks guard green)
- [ ] `pnpm run lint` exits 0
- [ ] Original `20260601029000_*.sql` is unchanged (`git status`)
- [ ] `SEMANTIC_SEARCH.md` "anon blocked" section marked resolved
- [ ] `plans/README.md` status row updated

## STOP conditions

- The wrapper is already SECURITY DEFINER (drift since `5daa274`) — nothing to do; report.
- The exact original signature can't be determined from `20260601029000_*.sql` — STOP (a wrong signature creates a second overloaded function).
- You cannot confirm the SQL applies (no local Supabase) AND cannot reason it is correct from the doc's verbatim fix — STOP and report rather than ship blind.
- The security advisor (`db:advisors:security`) flags the new DEFINER function — STOP and report.

## Maintenance notes

- SECURITY DEFINER + `SET search_path TO ''` is the safe pattern here because the
  body only calls a schema-qualified `private.` function and returns published
  data — no user-supplied identifiers reach SQL. A reviewer should confirm the
  body stays a pure pass-through (no dynamic SQL) so DEFINER can't be abused.
- This unblocks plan 028's `GET /events/{id}/similar` endpoint.
- If `p_limit` clamp (Step 4) was skipped, it remains an open hardening item.
