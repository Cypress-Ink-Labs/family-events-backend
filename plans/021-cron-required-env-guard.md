# Plan 021: Guard against missing cron env vars (no Railway migration)

> **Executor instructions**: Follow step by step; run every verification command. Honor STOP conditions.
> Update this plan's row in `plans/README.md` when done. This plan adds guards only — it does NOT change
> the Railway topology (one project, dashboard-managed, stays as-is).
>
> **Drift check (run first)**: `git diff --stat 07d7548..HEAD -- scripts/railway-cron-drift.mjs infra/railway-cron-drift/cron-services.json .github/workflows/railway-cron-drift.yml package.json cron`

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (adds checks; no infra/topology change)
- **Depends on**: none (chosen INSTEAD of plans 019/020 — keep one Railway project, guard the failure class)
- **Category**: dx / infra-safety
- **Planned at**: commit `07d7548`, 2026-06-18

## Why this matters

`cron-weekly-digest` crashed because its `SEND_WEEKLY_DIGEST_URL` Railway env var was empty — `cron-runner.sh`
fails fast with "missing URL arg" and the service goes CRASHED. The var lives only in the Railway dashboard,
so nothing in the repo or CI catches a missing/cleared one until a scheduled run crashes (and for a weekly
cron, that's up to a week late). We decided NOT to migrate Railway topology (one project is correct — see
the rejected 019/020). Instead, close the failure class cheaply with two guards:

1. **Static (repo-only)** — at PR time, prove every cron's required URL var is wired in the repo (Dockerfile
   ↔ IaC). Catches "added a cron, forgot its URL" before merge. No Railway access needed.
2. **Live (drift tooling)** — assert each cron service on Railway actually has its required env vars set and
   non-empty, *before* a run crashes. Extends the existing `railway-cron-drift` validator (which already runs
   in CI with Railway creds and already flags CRASHED deployments after the fact).

## Current state (facts the executor needs)

- Each cron's Dockerfile ENTRYPOINT passes one URL env var as `$1`, e.g.
  `cron/weekly-digest/Dockerfile`: `cron-runner.sh "$SEND_WEEKLY_DIGEST_URL" cron-weekly-digest`. Map:

  | service | dir | URL var | extra secret env |
  |---|---|---|---|
  | cron-tag-queue | cron/tag-queue | `PROCESS_TAG_QUEUE_URL` | — |
  | cron-scrape-sources | cron/scrape-sources | `SCRAPE_DUE_SOURCES_URL` | — |
  | cron-db-maintenance | cron/db-maintenance | `DB_MAINTENANCE_URL` | — |
  | cron-cleanup-stale | cron/cleanup-stale | `CLEANUP_STALE_RUNS_URL` | — |
  | cron-enrich-events | cron/enrich-events | `BACKFILL_EVENT_ENRICHMENT_URL` | `UNSPLASH_ACCESS_KEY` |
  | cron-send-reminders | cron/send-reminders | `SEND_REMINDERS_URL` | `VITE_VAPID_PRIVATE_KEY`, `VITE_VAPID_PUBLIC_KEY` |
  | cron-weekly-digest | cron/weekly-digest | `SEND_WEEKLY_DIGEST_URL` | — |
  | cron-review-events | cron/review-events | `PROCESS_EVENT_REVIEW_QUEUE_URL` | — |

  Every cron also needs `SUPABASE_SERVICE_ROLE_KEY`, `IS_CRON_ENABLED_URL`, `LOG_CRON_RUN_URL` (the
  `baseCronEnv` in `.railway/railway.ts`). `cron-runner.sh` checks `IS_CRON_ENABLED_URL`/`LOG_CRON_RUN_URL`
  presence and the `$1` URL (the "missing URL arg" exit).
- `.railway/railway.ts` already SETS every cron's URL via `fnUrl()`/`rpcUrl()` (plan 020-era commit) and
  `preserve()`s secrets.
- `infra/railway-cron-drift/cron-services.json` — per-service expected config (fields: `config_path`,
  `source_repo`, `root_directory`, `builder`, `dockerfile_path`, `cron_schedule`, `restart_policy_type`,
  `required_latest_deployment_status`, `forbidden_instance_statuses`). **No `required_env` field yet.**
- `scripts/railway-cron-drift.mjs` — the validator. `loadServiceConfigs()` reads the manifest;
  `loadLiveSources()` runs `railway status --json` + `railway service list --json`; `collectRailwayServiceState()`
  extracts fields from that live JSON; `validateRailwayCronState(expected, liveSources)` emits diagnostics +
  drives exit code. It has a **fixture mode**: `SPACELIFT_POC_FIXTURE=<path>` loads a JSON fixture instead of
  live Railway (used by `tests/railway-cron-poc.test.mjs` / `pnpm run railway:drift:test`). `runRailwayJson()`
  redacts secret-looking lines from errors (`secretKeyPattern`).
- CI: `.github/workflows/railway-cron-drift.yml` runs `node scripts/railway-cron-drift.mjs validate || true`
  (non-blocking "diagnostics") with `RAILWAY_API_TOKEN`, then a blocking Terraform `plan -detailed-exitcode`.
- Guard tests run via `pnpm run workspace:test` (node:test, 5 files in `tests/guards/`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Static guard | `node --test tests/guards/cron-env-vars.test.mjs` | pass |
| All guards | `pnpm run workspace:test` | pass |
| Validator unit test (fixture) | `pnpm run railway:drift:test` | pass incl. new missing-env case |
| Validator against live | `node scripts/railway-cron-drift.mjs validate` (needs `railway` auth/link) | diagnostics, non-zero if missing env |
| Inspect a service's var keys | `railway variables -s <svc> -e production --json` (keys only; never print secret values) | JSON |

## Scope

**In scope:**
- `infra/railway-cron-drift/cron-services.json` (add `required_env` per service).
- `scripts/railway-cron-drift.mjs` (collect live var keys + validate required env present/non-empty).
- `tests/railway-cron-poc.test.mjs` (fixture case for missing env) + a new fixture if needed.
- `tests/guards/cron-env-vars.test.mjs` (new static repo-only guard) + wire into `workspace:test` in `package.json`.
- `.github/workflows/railway-cron-drift.yml` (make the env-presence check blocking).

**Out of scope:**
- Any change to Railway topology / `.railway/railway.ts` project structure (one project stays).
- Printing or handling secret VALUES — only check key presence/non-empty; never log values.
- The web/mobile repos.

## Steps

### Step 1: Add `required_env` to the manifest
For each entry in `infra/railway-cron-drift/cron-services.json`, add a `required_env` array = the shared keys
(`SUPABASE_SERVICE_ROLE_KEY`, `IS_CRON_ENABLED_URL`, `LOG_CRON_RUN_URL`) + that service's URL var + its extra
secrets (per the table in "Current state"). Example for `cron-weekly-digest`:
`"required_env": ["SUPABASE_SERVICE_ROLE_KEY","IS_CRON_ENABLED_URL","LOG_CRON_RUN_URL","SEND_WEEKLY_DIGEST_URL"]`.

### Step 2: Static repo-only guard
Create `tests/guards/cron-env-vars.test.mjs` (node:test, model on `tests/guards/cron-runner-boundary.test.mjs`):
- For each cron dir, parse its `Dockerfile` ENTRYPOINT and extract the `$<NAME>_URL` it passes as `$1`.
- Assert that URL var is (a) listed in that service's `cron-services.json` `required_env`, and (b) SET (not
  `preserve()`) in `.railway/railway.ts` (grep the IaC text for the key with an `fnUrl(`/`rpcUrl(` value).
- Assert the manifest's service set == the `cron/*` dirs (no cron lacks a manifest entry).
Add `tests/guards/cron-env-vars.test.mjs` to the `workspace:test` script in `package.json`.

**Verify**: `node --test tests/guards/cron-env-vars.test.mjs` passes; `pnpm run workspace:test` passes.

### Step 3: Live env-presence check in the validator
In `scripts/railway-cron-drift.mjs`:
- Extend `loadServiceConfigs()` to carry `requiredEnv` from the manifest.
- Add a way to read each service's live variable KEYS. Either extend `loadLiveSources()` to also run
  `railway variables -s <name> -e <env> --json` per service, or add a dedicated collector. Capture **keys
  and emptiness only** — never store/log values (keep the `secretKeyPattern` redaction on any error output).
  Support the fixture path (`SPACELIFT_POC_FIXTURE`) so the unit test can supply a fake var map.
- In `validateRailwayCronState()`, for each expected service, push a diagnostic for every `requiredEnv` key
  that is missing or empty: e.g. `"cron-weekly-digest: required env SEND_WEEKLY_DIGEST_URL is missing/empty"`.
  These diagnostics must drive a non-zero exit (same path as the existing status mismatches).

**Verify**: `node scripts/railway-cron-drift.mjs validate` against a fixture with a missing var reports the
diagnostic and exits non-zero; against a complete fixture, exits 0.

### Step 4: Fixture unit test
In `tests/railway-cron-poc.test.mjs` (run by `pnpm run railway:drift:test`), add a case: a fixture where one
cron is missing its URL var → assert the validator yields the "required env … missing" diagnostic; and a
fixture where all are present → no env diagnostics. Reuse the existing fixture-loading pattern.

**Verify**: `pnpm run railway:drift:test` passes including the new cases.

### Step 5: Make CI catch it (blocking)
In `.github/workflows/railway-cron-drift.yml`, the validator currently runs as `... validate || true`
(non-blocking diagnostics). Add a blocking invocation for the env check — either drop `|| true` so a missing
required env fails the job, or add a dedicated step `node scripts/railway-cron-drift.mjs validate` (without
`|| true`) gated on Railway auth being available. Keep the Terraform drift step as-is.
- Confirm the CLI can reach the project in CI (it uses `RAILWAY_API_TOKEN`; verify `railway status --json`
  works headless — it may need a project id env like `RAILWAY_PROJECT_ID`/link. If headless link is not
  configured, wire it; if it can't be made to work in CI without interactive link, run the live check on a
  schedule (`workflow_dispatch`/cron) instead and keep the static guard (Step 2) as the PR gate — document
  which.)

**Verify**: a dry run of the workflow (or `act`, or manual `workflow_dispatch`) shows the env check executing
and failing when a var is absent.

## Done criteria

ALL must hold:
- [ ] `cron-services.json` has `required_env` for all 8 crons (shared keys + URL + extras)
- [ ] `tests/guards/cron-env-vars.test.mjs` exists, is in `workspace:test`, and passes (Dockerfile ↔ IaC ↔ manifest consistent)
- [ ] Validator reports + non-zero-exits on a missing/empty required env (fixture-proven)
- [ ] `pnpm run railway:drift:test` passes with the new cases; `pnpm run workspace:test` passes
- [ ] CI runs the live env-presence check in a blocking way (or, if headless auth is impossible, documented + the static guard gates PRs)
- [ ] No secret value is logged anywhere (only key presence/emptiness)
- [ ] `plans/README.md` row for 021 updated

## STOP conditions

- The `railway` CLI cannot authenticate/link headlessly in CI with `RAILWAY_API_TOKEN` — do NOT hardcode any
  token or interactive step; fall back to a scheduled `workflow_dispatch` live check + keep the static guard
  as the PR gate, and document the limitation.
- Reading a service's variables returns secret values that would land in logs — STOP; only request/keep keys
  + emptiness, and keep the redaction filter on all output.
- A cron's Dockerfile uses a URL var name not matching the table — re-derive from the live Dockerfile (it is
  truth), don't assume.

## Maintenance notes

- Adding a new cron now requires: a `cron/<name>/Dockerfile` ENTRYPOINT URL var + a `cron-services.json` entry
  with `required_env` + setting the URL in `.railway/railway.ts`. The static guard (Step 2) fails the PR until
  all three line up — that's the point.
- This keeps the one-project Railway topology and the dashboard-managed model; the guard simply makes a missing
  var loud at PR/CI time instead of silently at the next scheduled run.
- Reviewer: confirm no secret values can reach logs (Step 3 redaction), and that the static guard truly fails
  when a cron's URL is unset in the IaC.
