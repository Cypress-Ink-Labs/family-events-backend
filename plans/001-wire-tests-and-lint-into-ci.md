# Plan 001: Existing Deno + vitest tests and lint run in CI

> **Executor instructions**: Follow this plan step by step. Run every verification command and
> confirm the expected result before moving on. If anything in "STOP conditions" occurs, stop and
> report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- package.json .github/workflows/ci.yml supabase/functions/vitest.config.ts supabase/functions/deno.json`
> If any of these changed since this plan was written, compare the "Current state" excerpts below
> against the live files before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (adds gates; cannot break passing code — worst case it surfaces a pre-existing failure)
- **Depends on**: none
- **Category**: tests / dx
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

The repo has **50 test files** in `supabase/functions/` (42 Deno-style `*_test.ts` using `Deno.test`,
8 vitest-style `*.test.ts`), but **none of them run in CI or in `pnpm test`**. The root `test` script
only runs 5 node guard tests + the SQL DB tests. So the test suites covering auth, the SSRF guard,
HTML parsers, queue workers, push/email logic, and LLM classification are dead weight from CI's
perspective — a regression in any of them ships silently. Additionally `oxlint`/`oxfmt` are installed
but no `lint`/`format` script exists and CI never lints. This plan closes the verification hole so the
later plans' new tests actually protect the codebase.

## Current state

- `package.json:16-19` — the only test wiring:
  ```json
  "check": "pnpm --filter @cypress-ink-labs/contracts check && pnpm --filter @cypress-ink-labs/deploy-cli check",
  "test": "pnpm run workspace:test && pnpm run db:test",
  "workspace:test": "node --test tests/guards/cron-runner-boundary.test.mjs tests/guards/db-types-script.test.mjs tests/guards/deploy-cli-boundary.test.mjs tests/guards/supabase-function-auth-config.test.mjs tests/guards/migration-rollbacks.test.mjs",
  "db:test": "bash scripts/test.sh",
  ```
  `oxlint@^1.70.0` and `oxfmt@^0.55.0` are in `devDependencies` (`package.json:36-37`) but there is no
  `lint` or `format` script.
- `.github/workflows/ci.yml` — jobs are: `secret-scan`, `check` (runs `pnpm run check`),
  `workspace-guards` (runs `pnpm run workspace:test`), `type-drift`. **No job runs Deno tests, vitest, or lint.**
- `supabase/functions/vitest.config.ts` — globs only `_shared`:
  ```ts
  export default defineConfig({
    test: { include: ["_shared/**/*.test.ts"], environment: "node", includeTaskLocation: true },
  })
  ```
  But vitest `.test.ts` files also exist under `send-push/`, `send-reminders/`, `send-weekly-digest/`
  (run `find supabase/functions -name '*.test.ts'` → 8 files in 4 dirs), so the current glob misses 4 of them.
- The 42 `*_test.ts` files use `Deno.test(...)` (e.g. `supabase/functions/_shared/env_test.ts:12`,
  `_shared/auth_test.ts`) and import sibling modules with `.ts` extensions — they require the **Deno**
  runtime, not vitest. `supabase/functions/deno.json` provides the import map (`@supabase/supabase-js`,
  jsr deps) that `deno test` will use.
- Convention: this is a pnpm workspace; per-package scripts run via `pnpm -C <dir>` or `pnpm --filter`.
  CI uses `pnpm/action-setup@v6` + `actions/setup-node@v6` with `node-version: 24` and `cache: pnpm`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Install | `pnpm install --frozen-lockfile` | exit 0 |
| Typecheck | `pnpm run check` | exit 0 |
| Guard tests | `pnpm run workspace:test` | all pass |
| Deno present? | `deno --version` | prints a version (install if missing — see Step 1) |
| Deno tests | `deno test --allow-env --allow-net --allow-read` (cwd `supabase/functions`) | tests run; see Step 1 for permission tuning |
| vitest | `pnpm -C supabase/functions exec vitest run` | tests run |

## Steps

### Step 1: Get the Deno test suite running locally and record the exact invocation

`cd supabase/functions` and run `deno test` with no extra flags first. Deno will print which
permissions each test needs. Add only the permissions actually required (likely `--allow-env`,
`--allow-net`, `--allow-read`; some tests stub `fetch` and need none). Record the minimal working
command — you will reuse it in the npm script and CI.

- If `deno` is not installed: install via `curl -fsSL https://deno.land/install.sh | sh` (or the
  platform equivalent) for local work. The CI job (Step 4) uses `denoland/setup-deno@v2`.
- Some `*_test.ts` may currently fail (the whole point — they have never run). If a test fails because
  of a **real bug**, that is out of scope for this plan: record it in your final report and, if it
  blocks the suite, narrow the CI command to the passing directories with an explicit `log()`-style
  comment listing what was excluded and why. Do NOT fix product code in this plan.

**Verify**: the recorded `deno test ...` command exits 0 (or exits non-zero only on failures you have
documented as pre-existing real bugs, with the excluded set written down).

### Step 2: Broaden the vitest glob and confirm vitest runs

Edit `supabase/functions/vitest.config.ts` so `include` covers all vitest files, not just `_shared`:

```ts
test: { include: ["**/*.test.ts"], environment: "node", includeTaskLocation: true },
```

Add `exclude` for anything that must not be picked up if Step-1 reveals a Deno-only file accidentally
named `*.test.ts` (none known today — the split is clean: `*_test.ts` = Deno, `*.test.ts` = vitest).

**Verify**: `pnpm -C supabase/functions exec vitest run` discovers all 8 `.test.ts` files and they pass.

### Step 3: Add npm scripts

In root `package.json` `scripts`, add (keep existing scripts intact):

```json
"lint": "oxlint .",
"format": "oxfmt --check .",
"test:deno": "<the exact command recorded in Step 1>",
"test:functions": "pnpm -C supabase/functions exec vitest run",
```

Then extend `test` to include the function suites:

```json
"test": "pnpm run lint && pnpm run workspace:test && pnpm run test:functions && pnpm run test:deno && pnpm run db:test",
```

Place `db:test` last (it needs a running local Supabase, which CI provides in a dedicated job — see
Step 4 — so locally `pnpm test` may fail only on `db:test` if the DB isn't started; that is expected
and unchanged from today).

- If `oxlint .` produces a flood of pre-existing violations, do NOT auto-fix product code. Instead add
  a minimal `oxlintrc.json` / `.oxlintrc.json` at repo root that ignores generated and vendored paths
  (`node_modules`, `**/dist`, `packages/contracts/src/database.types.ts`, `graphify-out`,
  `.understand-anything`, `supabase/migrations`) and set the lint to report (not fail) only if the
  remaining set is large — record the count in your report and leave a follow-up note. The goal is a
  *running* lint gate, not a clean-up of the whole repo (that is a separate effort).

**Verify**: `pnpm run lint` exits 0 (or reports a documented, ignored-by-config set);
`pnpm run test:functions` and `pnpm run test:deno` both pass.

### Step 4: Add CI jobs

In `.github/workflows/ci.yml`, add two jobs modeled on the existing `workspace-guards` job (same
checkout / pnpm / node setup / `pnpm install --frozen-lockfile` with `NODE_AUTH_TOKEN`):

1. **`lint`** — runs `pnpm run lint`.
2. **`function-tests`** — sets up Deno with `denoland/setup-deno@v2` (pin a version, e.g. `v2.x`),
   runs `pnpm run test:functions` then `pnpm run test:deno`.

Do NOT add `db:test` here — it already runs via local Supabase only and the `type-drift` job already
spins up Supabase; leave DB testing as a separate concern unless it's trivial to add a `db-tests` job
that reuses the `supabase/setup-cli@v1` + `pnpm run db:start` pattern from `type-drift` and then
`pnpm run db:test`. If you add it, model it exactly on `type-drift` (lines 78-114) and stop Supabase
in an `if: always()` step.

**Verify**: `actionlint .github/workflows/ci.yml` if available, otherwise YAML-parse it
(`python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`) → no error.

## Test plan

- No new product tests in this plan — it *enables* the existing ones. The "test" is that the suites
  now execute and the new CI jobs are well-formed.
- After this lands, every later plan (004–011) adds its tests under `supabase/functions/**` and they
  run automatically.

## Done criteria

ALL must hold:

- [ ] `pnpm run lint` runs (exits 0 or documented ignored-set)
- [ ] `pnpm run test:functions` passes (all 8 vitest files discovered)
- [ ] `pnpm run test:deno` passes (or excludes only documented pre-existing failures)
- [ ] `.github/workflows/ci.yml` has a `lint` job and a `function-tests` job that invoke the above
- [ ] CI workflow YAML parses without error
- [ ] No product source under `supabase/functions/**` was modified except `vitest.config.ts` (`git status`)
- [ ] `plans/README.md` status row for 001 updated

## STOP conditions

Stop and report (do not improvise) if:

- The "Current state" excerpts don't match the live files (drift since `6c0db23`).
- More than ~5 `*_test.ts` files fail and the failures look like real product bugs, not test-harness
  issues — report the list; fixing product code is out of scope.
- `oxlint .` reports thousands of violations across product code — report the count and the top rules;
  do not mass-edit source.

## Maintenance notes

- For the reviewer: confirm the Deno permission flags are minimal (no blanket `--allow-all`) and that
  the CI `function-tests` job pins a Deno version.
- Follow-up deliberately deferred: actually fixing any product bugs surfaced by the now-running tests
  (file a finding), and driving the lint to zero violations across the whole repo.
