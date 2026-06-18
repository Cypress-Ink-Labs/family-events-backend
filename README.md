# family-events-backend

Backend for the **Family Events** app — a regional event aggregation platform
for Lafayette and Baton Rouge, Louisiana. Built on Supabase (Postgres + Deno
edge functions) with Railway cron containers for scheduled work and Terraform
IaC for infrastructure management.

## Repository layout

| Path                          | Description                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------- |
| `supabase/functions/`         | 23 Deno edge functions (scraping, tagging, notifications, admin)                            |
| `supabase/functions/_shared/` | Shared utilities imported across functions (auth, SSRF guard, LLM, geocode, CORS)           |
| `supabase/migrations/`        | 42 append-only SQL migrations; each must have a paired rollback in `supabase/rollbacks/`    |
| `supabase/tests/`             | pgTAP SQL test files for DB logic                                                           |
| `packages/contracts/`         | Generated TypeScript types (`database.types.ts`) + shared contracts                         |
| `packages/deploy-cli/`        | Internal CLI for deploying edge functions and Railway services                              |
| `cron/`                       | Alpine Docker containers; each runs `cron-runner.sh` to curl an edge function on a schedule |
| `infra/`                      | Terraform IaC for Railway infrastructure                                                    |
| `config/deploy.config.json`   | Canonical list of edge functions + Railway cron services + JWT settings                     |
| `tests/guards/`               | Node `node:test` guard tests (migration rollbacks, auth config, cron-runner boundary)       |
| `scripts/`                    | Bash/Node helper scripts for local development                                              |

## Local setup

> **Prerequisite**: `NODE_AUTH_TOKEN` must be set (GitHub PAT with
> `read:packages`) before `pnpm install` — see `.npmrc` and `.env.example`.

```bash
# 1. Install Node dependencies
pnpm install

# 2. Start local Supabase (Postgres, Auth, etc.)
pnpm run db:start

# 3. Generate TypeScript types from the local DB schema
pnpm run db:types

# 4. Install Deno dependencies for edge functions
pnpm run deno:install

# 5. Serve edge functions locally
pnpm run db:functions:serve
```

Stop the local database with `pnpm run db:stop`. Apply pending migrations with
`pnpm run db:migrate`.

## Verification

```bash
# TypeScript typecheck (contracts + deploy-cli)
pnpm run check

# All tests: guard tests (node:test) + DB integration tests
pnpm run test
```

`pnpm run workspace:test` runs only the guard tests; `pnpm run db:test` runs
the DB integration tests (requires `pnpm run db:start` first).

Deno function tests and vitest are not yet wired into CI — see `plans/001`.

## Deploy

```bash
# Deploy everything (edge functions + Railway services)
pnpm run deploy:all

# Interactive deploy CLI (select targets)
pnpm run deploy

# Railway IaC
pnpm run railway:plan          # preview infrastructure changes
pnpm run railway:drift:validate  # validate cron config drift
```

## Environment variables

Copy `.env.example` to `.env` and fill in the values. `.env.example` is the
authoritative list of required variables.

Key variables:

| Variable                    | Purpose                                             |
| --------------------------- | --------------------------------------------------- |
| `SUPABASE_URL`              | Your Supabase project URL                           |
| `SUPABASE_ANON_KEY`         | Supabase anonymous key                              |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service-role key (never expose to clients) |
| `RESEND_API_KEY`            | Resend API key for transactional email              |
| `RAILWAY_TOKEN`             | Railway API token for deployment                    |
| `NODE_AUTH_TOKEN`           | GitHub PAT (`read:packages`) for npm packages       |

## Docs

| Doc                                                                        | Description                                                                                  |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [`supabase/docs/PRODUCTION_SETUP.md`](supabase/docs/PRODUCTION_SETUP.md)   | Full production bring-up: migrations, bootstrap admin, deploy edge functions, email, Railway |
| [`supabase/docs/EMAIL.md`](supabase/docs/EMAIL.md)                         | Resend setup for Auth emails + `notify-email` application emails                             |
| [`supabase/docs/INVITE_GATE.md`](supabase/docs/INVITE_GATE.md)             | Invite-only registration GUC — how to enable/disable and verify                              |
| [`supabase/docs/LOCAL_LLM_TAGGING.md`](supabase/docs/LOCAL_LLM_TAGGING.md) | Running a self-hosted Qwen3/Ollama model on Railway as an OpenAI-compatible tag provider     |
| [`scripts/db/README.md`](scripts/db/README.md)                             | DB helper scripts reference                                                                  |
| [`plans/README.md`](plans/README.md)                                       | Active implementation plans and their status                                                 |
