# Plan 020: Model B — move the crons to their own IaC-managed Railway project

> **Executor instructions**: HIGH-RISK production migration. It creates a new Railway project, cuts the
> 8 cron jobs over to it, and decommissions the old ones — with a window where **double-firing crons could
> send duplicate emails to real users**. Follow every step and STOP condition. Do destructive steps
> (deleting old services) only after the new ones are verified. Update this plan's row in `plans/README.md`
> when done/blocked.
>
> **Drift check (run first)**: `git diff --stat c3278e6..HEAD -- .railway/railway.ts config/deploy.config.json infra/railway-cron-drift`

## Status

- **Priority**: P3
- **Effort**: L (multi-session; project setup + secret seeding + staged cutover)
- **Risk**: HIGH (duplicate user-facing emails during cutover; deleting live services)
- **Depends on**: chosen over plan 019's Model A (this is 019's "Model B" path)
- **Category**: migration / infra
- **Planned at**: commit `c3278e6`, 2026-06-18

## Why Model B (vs 019's Model A)

The crons live in the shared `family-events-ui` Railway project, which was built via the dashboard, so
`railway config apply` against it shows a destructive delete-all (no IaC baseline to reconcile). Model A
adopts that project but makes the **backend repo own `web`'s Railway config** (cross-repo coupling) and
still requires risky adoption of an unmanaged project.

**Model B sidesteps both problems**: a brand-new Railway project (`family-events-cron`) is a clean slate, so
`railway config apply` from `.railway/railway.ts` simply **CREATEs** the cron services — no delete-all, no
adoption. Ownership stays clean: the backend repo's IaC manages only its own crons; `web` stays in
`family-events-ui` managed by the web repo (`railway.toml`/`railpack`). The whole goal — IaC sets every
`*_URL` so a missing var can't crash a cron — is achieved on a project the IaC genuinely manages.

Cost: stand up a new project, re-seed secrets there, cut over without double-firing crons, decommission the
old ones, and update the deploy config / drift tooling.

## Current state (facts the executor needs)

- Live project `family-events-ui` / `production`: `web` (web repo) + 8 crons (this repo). Crons:

  | service | rootDir | schedule | extra secret env |
  |---|---|---|---|
  | cron-tag-queue | cron/tag-queue | `*/5 * * * *` | — |
  | cron-scrape-sources | cron/scrape-sources | `0 * * * *` | — |
  | cron-db-maintenance | cron/db-maintenance | `15 3 * * *` | — |
  | cron-cleanup-stale | cron/cleanup-stale | `*/30 * * * *` | — |
  | cron-enrich-events | cron/enrich-events | `*/15 * * * *` | `UNSPLASH_ACCESS_KEY` |
  | cron-send-reminders | cron/send-reminders | `0 11 * * *` | `VITE_VAPID_PRIVATE_KEY`, `VITE_VAPID_PUBLIC_KEY` |
  | cron-weekly-digest | cron/weekly-digest | `0 13 * * 1` | — |
  | cron-review-events | cron/review-events | `*/5 * * * *` | — |

- Every cron needs `SUPABASE_SERVICE_ROLE_KEY` (secret), `IS_CRON_ENABLED_URL`, `LOG_CRON_RUN_URL`, and its
  own target `*_URL`. URLs: `https://ufrjcnozcapskjtoakvf.supabase.co/functions/v1/<fn>`;
  kill-switch: `.../rest/v1/rpc/is_cron_enabled`. `restartPolicyType` is `NEVER` per
  `infra/railway-cron-drift/cron-services.json` (one-shot crons; do not retry).
- `.railway/railway.ts` currently targets `project("family-events-ui")` with these 8 crons (URLs SET,
  secrets `preserve()`). Model B re-points it to the new project.
- `config/deploy.config.json` `railway.services` lists `web` + the 8 crons together (used by deploy-cli +
  the `deploy-cli-boundary` guard, which cross-checks `cron-services.json`). Splitting the crons to a new
  project means this list must change.
- The cron runner POSTs run status to `LOG_CRON_RUN_URL` (→ `log-cron-run` fn → DB). The web admin "cron"
  view (`family-events-web` `apps/web/src/features/admin/hooks/operations/use-admin-crons.ts`) uses
  `railwayCron*` query keys — **confirm its data source** (Supabase `cron_runs`/RPC vs the Railway API). If
  it's DB-backed it's project-agnostic (the new crons still log to the same DB); if it calls the Railway API
  with a hardcoded project, it must be updated. (STOP condition below.)
- The kill switch (`is_cron_enabled`) is keyed by cron **label** in the DB and is shared by any service using
  that label — so old and new services with the same label both honor it. Useful for the cutover.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Auth | `railway whoami` | logged in as Jacob |
| List projects | `railway list` | (no `family-events-cron` yet) |
| Create project | `railway init --name family-events-cron` (or dashboard) | new project |
| Link | `railway link -p family-events-cron -e production` | linked |
| Read a live secret to copy | `railway variables -s <svc> -e production -p family-events-ui --kv` | **redact in any output** |
| Set var | `railway variables --set "K=V" -s <svc> -e production` | set |
| Plan / apply IaC | `railway config plan` / `railway config apply` | create-only diff / applied |
| Delete old service | `railway service delete <name> -p family-events-ui` (or dashboard) | removed |
| Guards | `pnpm run workspace:test` | pass |

## Scope

**In scope:** `.railway/railway.ts` (re-point to `family-events-cron`), `config/deploy.config.json`
(split web vs crons), `infra/railway-cron-drift/cron-services.json` + `scripts/railway-cron-drift.mjs` if they
gain a project reference, the new Railway project + its services/vars, decommissioning the 8 old cron services.
**Out of scope:** the `web` service / `family-events-ui` project (untouched beyond deleting the 8 crons),
the web repo, the mobile repo, secret *values* (copy via CLI, never commit), cron schedules/behavior.

## Steps

### Step 0: Pre-flight decisions + the admin-view check (STOP gates)
- Confirm the web admin cron view's data source (read `use-admin-crons.ts` + its query fns in the web repo).
  If it hits the **Railway API with a hardcoded `family-events-ui` project id**, this migration also requires
  a web-repo change — STOP and coordinate before proceeding. If it's DB-backed (`cron_runs`), continue.
- Pick the new project name (`family-events-cron`) + region (match current, e.g. `us-west2`).

### Step 1: Create the new project + environment
`railway init --name family-events-cron` (or dashboard), ensure a `production` environment, `railway link -p family-events-cron -e production`.

### Step 2: Re-point the IaC to the new project
Edit `.railway/railway.ts`: `project("family-events-cron", { resources: [cronJobs] })` (was `family-events-ui`).
Keep the 8 cron services, each `*_URL` SET, secrets `preserve()`. Set `restartPolicyType: "NEVER"` to match
`cron-services.json` (the current file has `ON_FAILURE` — fix it here so apply matches intended one-shot behavior;
this is in scope for B). Keep `watchPatterns` as `cron/<dir>/**` (this repo's real layout).

**Verify**: `railway config plan` (linked to the new empty project) shows **create-only** changes (8 services +
group), **zero deletes**. If any delete appears, STOP.

### Step 3: Apply (creates services) + seed secrets
`railway config apply` → creates the 8 cron services with URLs set and secrets unset. Then copy each secret
from the old project into the new one (do NOT print values):
- All 8: `SUPABASE_SERVICE_ROLE_KEY` (read from any old cron service, set on each new one).
- `cron-enrich-events`: `UNSPLASH_ACCESS_KEY`.
- `cron-send-reminders`: `VITE_VAPID_PRIVATE_KEY`, `VITE_VAPID_PUBLIC_KEY`.
Use `railway variables --set` piped from the old value without echoing it.

**Verify**: for each new cron, `railway variables -s <svc> -e production --kv | grep -iE '_URL='` shows the URL,
and `... | grep -c SUPABASE_SERVICE_ROLE_KEY` is 1 (don't print the value).

### Step 4: Cutover without double-firing (the dangerous part)
Old and new crons would both fire on the same schedule → **duplicate work + duplicate emails**. Cut over per job:
- **Low-frequency / non-user-facing first** (`cron-cleanup-stale`, `cron-db-maintenance`): let the new one run
  once, confirm green in the new project's logs, then delete the old service (Step 5) — a brief overlap here is
  harmless (idempotent maintenance).
- **Email-sending crons** (`cron-send-reminders` `0 11`, `cron-weekly-digest` `0 13 Mon`): cut over **outside
  their scheduled window** so only one project ever fires in a given day. Use the `is_cron_enabled` kill switch
  (disable the label in the DB) to hold both off, delete the old service, then re-enable — so exactly one
  service exists when the next scheduled time arrives.
- **High-frequency queue crons** (`*/5`, `*/15`): a short overlap is mostly idempotent (queue workers claim
  rows transactionally), but minimize it — delete the old service promptly after the new one is verified.

**Verify**: at no point are two services with the same label both enabled and scheduled to fire. Document the
cutover order + timing you used.

### Step 5: Decommission the old crons
Delete the 8 cron services from `family-events-ui` (CLI or dashboard). **Leave `web` untouched.**

**Verify**: `family-events-ui` retains only `web`; `family-events-cron` has the 8 crons running green.

### Step 6: Update deploy config + drift tooling + commit
- `config/deploy.config.json`: split `railway.services` so the crons reference the new project (or remove them
  from this repo's deploy list if deploy-cli no longer deploys crons here). Keep the `deploy-cli-boundary` guard
  green — adjust it / `cron-services.json` consistently.
- Re-run `pnpm run workspace:test` (guards) until green.
- Confirm the web admin cron view still shows the jobs (Step 0 source). If DB-backed, it Just Works.
- Commit (`.railway/railway.ts`, `config/deploy.config.json`, drift tooling) with a Conventional Commit; verify
  no secret value committed (`grep -iE 'service_role|vapid|access_key' .railway/railway.ts` → only `preserve()`).

## Done criteria

ALL must hold:
- [ ] New project `family-events-cron` runs all 8 crons green; each `*_URL` set; secrets present (not printed)
- [ ] `railway config plan` for the new project is create/no-op (never a delete of a pre-existing service)
- [ ] Old 8 crons deleted from `family-events-ui`; `web` untouched and still serving
- [ ] No duplicate emails sent during cutover (verify reminders/weekly-digest fired once)
- [ ] `config/deploy.config.json` + drift tooling updated; `pnpm run workspace:test` passes
- [ ] Web admin cron view still works (data source confirmed)
- [ ] No secret value committed; secrets remain `preserve()` in IaC
- [ ] `plans/README.md` row for 020 updated

## STOP conditions

- The web admin cron view calls the **Railway API with a hardcoded `family-events-ui` project** — coordinate a
  web-repo change before migrating (else the admin "cron" page breaks).
- `railway config plan` for the new project shows any **delete** (it should be create-only on an empty project).
- You cannot read a required secret from the old project to copy it — STOP (don't apply with empty secrets;
  crons would fail auth).
- Cutover timing can't guarantee a single firing service for the email crons — STOP and schedule a maintenance
  window; duplicate emails to users are not acceptable.
- Deleting an old cron service would also remove shared config `web` depends on — STOP (it shouldn't; verify).

## Maintenance notes

- After this, the crons are fully IaC-managed: change env/schedule in `.railway/railway.ts` + `railway config apply`,
  never the dashboard. A missing `*_URL` is impossible (IaC sets it). Document this in `CLAUDE.md`/README.
- `web` and the crons now live in **separate Railway projects** — update any runbook/screenshots that assumed
  one project. The web repo continues to own `web` via `railway.toml`/`railpack`.
- Reviewer: scrutinize (1) the create-only plan before apply, (2) the cutover timing for the two email crons,
  (3) that no secret leaked into the committed IaC.
- If duplicate-email risk during cutover is unacceptable even with the kill switch, consider blue/green by
  label (rename new-project labels, migrate the kill-switch + admin view to the new labels, then retire old).
