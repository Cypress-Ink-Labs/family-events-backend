# Plan 003: Root `README.md` and `CLAUDE.md` exist and describe how to work here

> **Executor instructions**: Follow step by step. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- package.json supabase/docs config/deploy.config.json`
> Confirm the script names and doc paths referenced below still exist before writing about them.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (new docs only)
- **Depends on**: none
- **Category**: docs / dx
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

The repo has no root `README.md` and no `CLAUDE.md`/`AGENTS.md`. It is a multi-layer Supabase backend
(29 Deno edge functions, 42 SQL migrations, Node packages, Dockerized Railway cron, Terraform IaC) with
the local-dev sequence scattered across `package.json` scripts and four docs under `supabase/docs/`.
A new contributor — or an agent executing these plans — has to reverse-engineer the bootstrap steps and
the cron→function→queue→DB data flow. Both files are pure documentation and high leverage for an
agent-driven repo.

## Current state

- No `README.md`, `CLAUDE.md`, or `AGENTS.md` at repo root (confirm: `ls README.md CLAUDE.md AGENTS.md`).
- Existing docs: `supabase/docs/EMAIL.md`, `INVITE_GATE.md`, `LOCAL_LLM_TAGGING.md`, `PRODUCTION_SETUP.md`;
  `scripts/db/README.md`; `packages/contracts/CHANGELOG.md`.
- Local-dev scripts (`package.json:6-29`): `db:start`, `db:stop`, `db:migrate`, `db:types`,
  `db:functions:serve`, `deno:install`, `check`, `test`, `workspace:test`, `db:test`, `deploy`, `deploy:all`,
  `railway:*`.
- Deploy surface: `config/deploy.config.json` lists 23 edge functions + 8 Railway cron services + `web`.
- Architecture (verified during audit, summarize — don't copy verbatim): cron containers in `cron/*`
  (Alpine + `cron-runner.sh` curling an edge function on a schedule) → edge functions in
  `supabase/functions/*` → enqueue work into Postgres queue tables via RPCs → queue-worker functions
  (`process-*-queue`) drain them → LLM tag/enrich, geocode, embed → admin review → notify
  (`send-reminders`, `send-weekly-digest`, `process-notification-queue`, `send-push`).

## Steps

### Step 1: Write root `README.md`

Cover, concisely:

- **What this is**: backend for the Family Events app (regional event aggregation — Lafayette / Baton
  Rouge LA), built on Supabase (Postgres + Deno edge functions) with Railway cron + IaC.
- **Layout**: one line each for `supabase/functions/`, `supabase/migrations/`, `supabase/functions/_shared/`,
  `packages/*`, `cron/*`, `infra/`, `config/deploy.config.json`, `tests/guards/`, `supabase/tests/`.
- **Local setup**, in order, using the real scripts: `pnpm install` → `pnpm run db:start` →
  `pnpm run db:types` → `pnpm run deno:install` → `pnpm run db:functions:serve`. Note `NODE_AUTH_TOKEN`
  must be set for install (see `.npmrc`).
- **Verification**: `pnpm run check`, `pnpm run test` (and what each covers — after plan 001 lands,
  update to mention lint + function tests).
- **Deploy**: `pnpm run deploy` / `pnpm run deploy:all` (deploy-cli); Railway via `railway:*`.
- **Docs index**: link the four `supabase/docs/*` files with a one-line description each (this satisfies
  the "no navigation between docs" gap too).
- **Environment**: point to `.env.example` (after plan 002, it is the authoritative var list).

### Step 2: Write root `CLAUDE.md`

Aimed at agents/contributors doing focused changes. Include:

- **Architecture overview**: the cron → edge function → queue → worker → notify flow from "Current state".
- **Key systems & where they live**: auth (`_shared/auth.ts`, `service-role-handler.ts`, `admin-handler.ts`),
  SSRF guard (`_shared/guarded-fetch.ts`, `url-validation.ts`), LLM (`_shared/llm-*.ts`, `classification.ts`),
  geocode (`_shared/geocode.ts`), CORS allowlist (`_shared/cors.ts`).
- **Conventions**: Deno functions import siblings with `.ts` extensions and use the import map in
  `supabase/functions/deno.json`; tests are `*_test.ts` (Deno) or `*.test.ts` (vitest); migrations are
  append-only and must ship a paired rollback in `supabase/rollbacks/` (`tests/guards/migration-rollbacks.test.mjs`);
  DB types are generated (`pnpm run db:types`) — never hand-edit `packages/contracts/src/database.types.ts`;
  Conventional Commits.
- **Guardrails**: don't commit secrets (`.env` is gitignored); `verify_jwt` settings live in
  `supabase/config.toml` and must stay in sync with `config/deploy.config.json` `noVerifyJwtFunctions`.
- **Where the plans live**: `plans/` (this directory).

Keep `CLAUDE.md` tight (a map, not a manual). Do not duplicate the whole README.

**Verify**: both files exist and all paths/scripts they mention resolve:

```
ls README.md CLAUDE.md
for f in $(grep -oE '(supabase|packages|config|cron|infra|tests|scripts)/[A-Za-z0-9_./-]+' README.md CLAUDE.md | sort -u); do test -e "$f" || echo "MISSING: $f"; done
```

→ no `MISSING:` lines. (Some matches may be directories or globs — sanity-check, don't blindly trust.)

## Done criteria

- [ ] `README.md` and `CLAUDE.md` exist at repo root
- [ ] Every concrete path/script referenced resolves (the verify loop prints no real `MISSING:`)
- [ ] Local-setup steps match the actual `package.json` script names
- [ ] No source/config files modified (`git status` shows only the two new docs)
- [ ] `plans/README.md` row for 003 updated

## STOP conditions

- A script or doc path referenced here no longer exists (drift) — re-derive from `package.json` and `ls supabase/docs`.
- You find conflicting setup instructions between this plan and `supabase/docs/PRODUCTION_SETUP.md` —
  prefer the doc, note the discrepancy in your report.

## Maintenance notes

- After plan 001 lands, update the README "Verification" section to mention `pnpm run lint`,
  `test:functions`, `test:deno`.
- Reviewer: check the architecture description against reality — an inaccurate map is worse than none.
