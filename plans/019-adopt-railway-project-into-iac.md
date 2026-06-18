# Plan 019: Bring the live Railway project under IaC management (`.railway/railway.ts`)

> **Executor instructions**: This is a HIGH-RISK infrastructure migration against a **production**
> Railway project that currently runs the live site + 8 cron jobs. A wrong `railway config apply`
> **deletes running services**. Follow every step, run every gate, and treat every STOP condition as a
> hard stop. **Never run `railway config apply` against production while the plan shows a single
> `resource.delete`.** When done (or blocked), update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat add0f0b..HEAD -- .railway/railway.ts config/deploy.config.json infra/railway-cron-drift`
> If `.railway/railway.ts` changed since this plan was written, re-read it and the "Current state"
> below before proceeding.

## Status

- **Priority**: P3
- **Effort**: L (multi-session; design decision + careful staged apply)
- **Risk**: HIGH (destructive to a live prod project if applied wrong)
- **Depends on**: none (but supersedes the "reference-only" posture noted in `.railway/railway.ts`)
- **Category**: migration / infra
- **Planned at**: commit `add0f0b`, 2026-06-18

## Why this matters

The cron services are dashboard/CLI-managed on Railway; their env vars (e.g. `SEND_WEEKLY_DIGEST_URL`)
live only in the dashboard. A missing/cleared var silently crashes a cron — that is exactly what took
down `cron-weekly-digest` (empty URL → `cron-runner.sh` "missing URL arg" → CRASHED). The repo has an
IaC file (`.railway/railway.ts`) but it is **not** the source of truth Railway actually applies: it was
hand-written, so `railway config plan` can't reconcile it against the live project and shows a full
**delete-all** (10 `resource.delete`, 0 creates). This plan makes the IaC genuinely manage the project so
that env vars (and service config) are version-controlled and a missing var is impossible end-to-end.

## Current state (facts the executor needs)

- Live Railway project: **`family-events-ui`** / environment **`production`**. It contains: a `web`
  service (`family-events.org`, sourced from the **web** repo) + a "Cron Jobs" group of **8** services
  sourced from this backend repo (`Cypress-Ink-Labs/family-events-backend`): `cron-tag-queue`,
  `cron-scrape-sources`, `cron-db-maintenance`, `cron-cleanup-stale`, `cron-enrich-events`,
  `cron-send-reminders`, `cron-weekly-digest`, `cron-review-events`.
- The product spans **three repos** that all deploy into this one Railway project: **web**, **backend**
  (this repo — owns the crons), **mobile** (no Railway service).
- `.railway/railway.ts` (this repo) currently declares the 8 crons (project renamed to `family-events-ui`,
  `web` removed) with each cron's `*_URL` SET via `fnUrl()`/`rpcUrl()` helpers and secrets `preserve()`d.
  It compiles (`railway config plan` → `ok:true`, no diagnostics) but the plan shows delete-all because it
  was hand-authored, not pulled from the live project.
- Live URL pattern (verified): `https://ufrjcnozcapskjtoakvf.supabase.co/functions/v1/<fn>` and
  `.../rest/v1/rpc/is_cron_enabled`.
- Pre-existing live↔IaC drifts beyond addresses: live `restartPolicyType: NEVER` (matches
  `infra/railway-cron-drift/cron-services.json`) vs the hand-written IaC's `ON_FAILURE`; live
  `watchPatterns: apps/cron-*/**` vs IaC `cron/*/**`.
- `railway` CLI is **5.15.0**, logged in as Jacob. The repo also pins `railway@^3.3.2` as a devDep (the IaC
  runtime). `cron-services.json` + `scripts/railway-cron-drift.mjs` are the *current* drift-enforcement
  mechanism (guard test `tests/guards/cron-runner-boundary.test.mjs` checks the sync script + runner).

## The adoption mechanism (how Railway IaC takes over an existing project)

`railway config` subcommands:
- `railway config pull` — **imports the linked project's current config into `.railway/railway.ts`**
  (this is the adoption primitive — it generates IaC whose resource addresses match the live resource IDs,
  so a subsequent `plan` reconciles instead of delete-all).
- `railway config plan` — preview changes (read-only).
- `railway config apply` — apply IaC to the linked project (**mutating**).
- `railway config init` — create/import IaC.
- `railway environment new|link|delete|list` — manage isolated environments for dry-runs.

The core idea: `pull` to get a clean baseline that matches live → make only the intended edits (codify URLs)
→ `plan` must show **only** those var updates (zero deletes) → `apply`.

## The blocking decision (resolve BEFORE applying)

Railway IaC treats `.railway/railway.ts` as the **full desired state of the project** — anything in the
project but not in the IaC is planned for **deletion**. The project is shared by 3 repos. So adoption forces
one of two models; **this plan cannot proceed to apply until the operator picks one**:

- **Model A — single-owner IaC (simplest).** The backend repo's `.railway/railway.ts` declares the **whole**
  project: `web` (sourced from the *web* repo) + all 8 crons. The web repo does NOT manage Railway IaC.
  One `railway config apply` (from this repo) manages everything. Trade-off: backend repo owns `web`'s
  Railway config — contradicts the earlier "web owned by web repo" preference.
- **Model B — split projects (cleanest ownership, bigger migration).** Create a **separate** Railway project
  for the crons (e.g. `family-events-cron`), recreate the 8 cron services + their env vars + cron schedules
  there, adopt THAT project via this repo's IaC, and leave `web` in `family-events-ui` managed by the web
  repo. Trade-off: a real service-recreation migration (downtime/cutover for the crons; re-set all env vars).

Recommended: **Model A** for speed if the team accepts the backend repo owning the full project IaC;
**Model B** if repo-ownership boundaries must hold. Do not guess — see STOP conditions.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Confirm auth | `railway whoami` | logged in |
| Link project+env | `railway link -p family-events-ui -e production` | "linked successfully" |
| List environments | `railway environment list` | shows `production` (+ any test env) |
| New dry-run env | `railway environment new iac-adopt-test` | created |
| Pull live → IaC | `railway config pull` | rewrites `.railway/railway.ts` from live |
| Preview | `railway config plan` (or `pnpm run railway:plan`) | JSON with `changeSet.changes` |
| Apply | `railway config apply` | **mutating — gated, see steps** |
| Inspect a service's vars | `railway variables -s <svc> -e <env> --kv \| grep -iE '_URL='` | URL lines only (never print secret lines) |
| Drift guard still green | `pnpm run workspace:test` | passes |

## Scope

**In scope:**
- `.railway/railway.ts` (the IaC).
- A throwaway Railway environment for dry-runs (`iac-adopt-test`), deleted at the end.
- Possibly `config/deploy.config.json` / `infra/railway-cron-drift/cron-services.json` if the adoption changes
  how drift is tracked (coordinate — don't silently diverge them).

**Out of scope:**
- Any change to the `web` service's runtime, the web repo, or the mobile repo.
- Editing secret values (service-role key, VAPID, Unsplash) — those stay `preserve()` forever.
- Changing cron schedules or restart policy as a side effect — only adopt what's live unless the operator
  explicitly asks to also fix the `NEVER` vs `ON_FAILURE` / `watchPatterns` drift.

## Steps

### Step 0: Get the decision (Model A or B) — STOP if unanswered
Do not proceed past here without the operator choosing Model A or B (see "The blocking decision"). Record
the choice in this plan and in `plans/README.md`.

### Step 1: Back up the current curated IaC
`cp .railway/railway.ts /tmp/railway.curated.ts`. The next step overwrites `.railway/railway.ts`; you will
re-apply the URL edits onto the pulled baseline, using this copy as the reference for which vars to set.

### Step 2: Pull the live baseline
`railway link -p family-events-ui -e production` then `railway config pull`. This rewrites
`.railway/railway.ts` to mirror the live project (correct resource addresses, all services, real env-var
shapes). Inspect the diff: `git diff .railway/railway.ts`. Confirm it now contains the live resources
(`web` + 8 crons) with addresses/IDs that match live.

**Verify**: `railway config plan` now shows **zero `resource.delete`** (a freshly pulled IaC should be a
no-op against the project it was pulled from). Parse the change kinds:
`pnpm run railway:plan` → in the JSON, `changeSet.changes` should be empty or all no-ops.
If it still shows deletes, STOP — the pull didn't reconcile; do not continue.

### Step 3: Reconcile to the chosen model
- **Model A**: keep all pulled resources; edit so each cron's target `*_URL` (and `LOG_CRON_RUN_URL`,
  `IS_CRON_ENABLED_URL`) is SET to the values in `/tmp/railway.curated.ts` (the `fnUrl()`/`rpcUrl()` form)
  instead of `preserve()`; keep `web` as pulled; keep all secrets `preserve()`.
- **Model B**: this plan's apply targets a NEW project — first create it (`railway environment`/project
  setup is out of this file's depth; treat Model B as its own follow-up plan and STOP here with a note).

**Verify**: `railway config plan` shows **only** `variable.set`/update changes for the cron URL vars and
**zero** `resource.delete` and zero changes to `web` or to any secret var. Confirm by parsing
`changeSet.changes`: every change `kind` must be a variable set on a cron service; assert no `resource.delete`
and no change whose target is `web` or a secret key (`SUPABASE_SERVICE_ROLE_KEY`, `VITE_VAPID_*`,
`UNSPLASH_ACCESS_KEY`).

### Step 4: Dry-run in an isolated environment first
`railway environment new iac-adopt-test` (or link an existing non-prod env), `railway link -e iac-adopt-test`,
then `railway config plan` and — only if clean — `railway config apply` against that env. Confirm the crons
exist + are configured as expected there. This proves the apply is non-destructive before touching production.
(Note: a new environment may not copy secret values; that's fine for validating structure/URLs.)

**Verify**: in `iac-adopt-test`, the 8 crons exist with the URL vars set; nothing was deleted. Re-link to
production afterward: `railway link -e production`.

### Step 5: Apply to production (gated)
ONLY after Steps 2–4 are green: `railway link -e production`, `railway config plan` (final confirm: zero
deletes), then `railway config apply`. Immediately verify each cron's `*_URL` is set
(`railway variables -s <svc> -e production --kv | grep -iE '_URL='`) and that `web` is untouched.

### Step 6: Reconcile the drift tooling + commit
- If adoption changes how drift is tracked, update `infra/railway-cron-drift/cron-services.json` /
  `scripts/railway-cron-drift.mjs` accordingly and keep `pnpm run workspace:test` green.
- Commit the final `.railway/railway.ts` (Conventional Commit). Do NOT commit any pulled secret values —
  re-confirm secrets are `preserve()` and no plaintext secret leaked into the file
  (`grep -iE 'service_role|vapid|access_key|secret' .railway/railway.ts` → only `preserve()` / comments).
- `railway environment delete iac-adopt-test`.

## Done criteria

ALL must hold:

- [ ] Operator chose Model A or B (recorded here + in README)
- [ ] `railway config plan` against production shows **zero `resource.delete`** and only the intended cron
      `*_URL` variable sets
- [ ] Production apply done; every cron `*_URL` confirmed set; `web` unchanged; all crons' last run not crashed
- [ ] No secret value committed to `.railway/railway.ts` (`grep` check passes; secrets remain `preserve()`)
- [ ] `pnpm run workspace:test` passes (drift guards green)
- [ ] `iac-adopt-test` environment deleted
- [ ] `plans/README.md` row for 019 updated

## STOP conditions

Stop and report (do not improvise) if:
- The Model A/B decision hasn't been made (Step 0).
- After `railway config pull`, `railway config plan` still shows **any** `resource.delete` — the baseline
  didn't reconcile; applying would be destructive.
- The plan would change or delete the `web` service, or change any secret variable.
- `railway config pull` writes plaintext secret values into the file (do not commit; report — secrets must
  stay `preserve()`).
- You cannot create/link a non-prod environment for the dry-run (Step 4) — do not apply straight to prod.
- Model B is chosen — stop and write it as its own plan (separate Railway project + cron recreation is a
  larger migration than this file covers).

## Maintenance notes

- After adoption, env vars + service config are version-controlled: change them in `.railway/railway.ts` +
  `railway config apply`, not the dashboard. Document this in `CLAUDE.md`/README so the dashboard stops being
  the source of truth.
- The whole point: a missing `*_URL` becomes impossible because the IaC sets it. Keep new crons' URLs set
  (not `preserve()`); only secrets stay `preserve()`.
- Reviewer: the single thing to scrutinize is the `railway config plan` output before any apply — zero
  `resource.delete` is the non-negotiable gate.
- If the team later wants strict per-repo ownership, revisit Model B (separate cron project) — record the
  decision so this isn't re-litigated.
