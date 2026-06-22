# CLAUDE.md — agent/contributor map

A focused reference for agents and contributors making targeted changes. Read
`README.md` for the full setup walkthrough.

## Architecture: data flow

```
cron containers (cron/*)
  └─ curl edge function on schedule (cron-runner.sh + Railway cron)
       └─ supabase/functions/scrape-due-sources  → enqueues source IDs
       └─ supabase/functions/process-source-queue  → runs scrape-source per source
            └─ supabase/functions/scrape-source  → inserts draft events
                 └─ enqueues tag + enrich work
       └─ supabase/functions/process-tag-queue  → supabase/functions/tag-event
       └─ supabase/functions/process-event-review-queue  → admin review step
       └─ supabase/functions/backfill-event-enrichment / embed-event / geocode
  └─ notify path:
       supabase/functions/send-reminders
       supabase/functions/send-weekly-digest
       supabase/functions/process-notification-queue  → supabase/functions/send-push
```

Each cron container is a minimal Alpine image. The actual scheduling logic is
entirely in `cron-runner.sh` (canonical copy: `cron/_shared/cron-runner.sh`;
per-dir copies are synced by `scripts/sync-cron-runner.sh`; drift is caught by
`tests/guards/cron-runner-boundary.test.mjs`).

## Key systems and where they live

| System               | Files                                                                                               |
| -------------------- | --------------------------------------------------------------------------------------------------- |
| Auth helpers         | `supabase/functions/_shared/auth.ts`, `_shared/service-role-handler.ts`, `_shared/admin-handler.ts` |
| SSRF guard           | `supabase/functions/_shared/guarded-fetch.ts`, `_shared/url-validation.ts`                          |
| LLM (OpenAI + local) | `supabase/functions/_shared/llm-config.ts`, `_shared/llm-openai.ts`, `_shared/classification.ts`    |
| Geocoding            | `supabase/functions/_shared/geocode.ts`                                                             |
| CORS allowlist       | `supabase/functions/_shared/cors.ts`                                                                |
| Generated DB types   | `packages/contracts/src/database.types.ts` — **never hand-edit**                                    |
| Deploy config        | `config/deploy.config.json` — canonical list of functions + Railway services + JWT settings         |
| Plans                | `plans/` — active implementation plans                                                              |

## Conventions

**Deno functions**

- Import siblings with `.ts` extensions.
- Use the import map in `supabase/functions/deno.json`.
- Tests are `*_test.ts` (Deno native) or `*.test.ts` (vitest).

**Migrations**

- Append-only. Never edit an existing migration.
- Every new migration must have a paired rollback SQL file in `supabase/rollbacks/`.
- The guard `tests/guards/migration-rollbacks.test.mjs` fails if a rollback is missing.

**DB types**

- Run `pnpm run db:types` to regenerate `packages/contracts/src/database.types.ts`.
- Do not hand-edit that file.

**Commits**: Conventional Commits (`feat|fix|refactor|build|ci|chore|docs|style|perf|test`).

## Deployment

Migrations + edge functions + `cron-*` Railway services deploy via GitHub Actions
(`.github/workflows/deploy.yml`) after `ci` passes on `main`, gated by a one-click
approval on the `production` environment (Railway auto-deploy is disabled). Merging
does **not** deploy by itself — make schema changes backward-compatible and deploy
them before dependent web code. See `docs/DEPLOYMENT.md`.

## Guardrails

- `.env` is gitignored — never commit secrets.
- `verify_jwt` settings live in both `supabase/config.toml` and `config/deploy.config.json`
  (`supabase.noVerifyJwtFunctions`). Keep them in sync; the guard test
  `tests/guards/supabase-function-auth-config.test.mjs` will catch drift.
- SSRF: external HTTP calls from edge functions must go through `guarded-fetch.ts` / `url-validation.ts`.
- CORS: use the shared allowlist in `_shared/cors.ts` rather than inline origins.

## Verification commands

```bash
# TypeScript typecheck
pnpm run check

# All tests
pnpm run test

# Guard tests only (no local DB needed)
pnpm run workspace:test

# Deno function tests (run from supabase/functions/)
cd supabase/functions && deno test --allow-env --allow-read

# vitest (run from supabase/functions/)
cd supabase/functions && ../../node_modules/.bin/vitest run
```
