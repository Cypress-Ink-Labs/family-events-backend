# Deployment

How `family-events-backend` reaches production.

## What deploys, and how

| Artifact | Mechanism | Gate |
| --- | --- | --- |
| **DB migrations + edge functions** | GitHub Actions `deploy.yml` → `family-events-deploy` CLI | after `ci` succeeds on `main`, one-click approval on the **`production`** environment |
| **`cron-*` Railway services** | same `deploy.yml`, Railway step (`deploy railway:crons`) | same approval gate |
| **`web` Railway service** | web repo's `deploy.yml` (`railway up`) | web repo's `production` approval gate |
| **`@cypress-ink-labs/contracts`** package | `publish-packages.yml` | push to `main` touching `packages/contracts/{src,package.json}` or `.changeset/**` |

Railway's own auto-deploy-on-push is **disabled** for these services so GitHub Actions is the single, CI-gated deploy path.

## GitHub Actions CD (`deploy.yml`)

1. `ci` passes on `main` (or run `deploy.yml` via **workflow_dispatch**).
2. The `deploy` job pauses on the `production` environment until a required reviewer approves.
3. On approval it:
   - **Supabase first** (no Railway dependency): applies migrations (`supabase db push --linked --include-all`, auto-linking the project) → deploys every edge function.
   - **Railway crons**: `railway link` then `deploy railway:crons` (ordered; `cron-review-events` bootstraps from `cron-enrich-events`).

### Required GitHub secrets

| Secret | Purpose |
| --- | --- |
| `SUPABASE_ACCESS_TOKEN` | Supabase management API (link + functions deploy) |
| `SUPABASE_PROJECT_REF` | Project ref (`ufrjcnozcapskjtoakvf`) |
| `SUPABASE_DB_PASSWORD` | DB password for `db push` / `link` |
| `RAILWAY_API_TOKEN` | (existing) Railway account token for cron deploys |
| `SUPABASE_SERVICE_ROLE_KEY` | (existing) |

## Manual / local deploy

```bash
bash scripts/supabase.sh link --project-ref <ref>   # one-time
pnpm run deploy:all                                  # migrations + functions + crons
pnpm --filter @cypress-ink-labs/deploy-cli cli deploy --all --yes --dry-run   # preview
```

The CLI auto-links the project in CI when `SUPABASE_ACCESS_TOKEN` + `SUPABASE_DB_PASSWORD` are set.

## Migration ordering (expand/contract)

The two repos have independent pipelines, so **make schema changes backward-compatible** and deploy them **before** the code that depends on them:

- New columns/tables/RPCs are additive; old code keeps working without them.
- For a cross-repo change (e.g. a new RPC consumed by the web app), approve the **backend** `production` deploy **before** the web one. The approval gate makes the ordering explicit.
- Removals are a separate, later change once nothing references the old shape.

A web release must never call an RPC/column introduced in the same release — that caused a brief prod break before CD existed (see CIL-190).

## Deployment status

The pg-boss dashboard listens on `dashboard.family-events.railway.internal:3001`; external access is firewalled with 403. It connects over Railway IPv6 to the Supabase direct endpoint using the dedicated `pgboss_dashboard` login and the pinned Supabase CA. That login has no pg-boss write privileges.

U33 has transferred the scrape, tag, and review families:

- `CUTOVER_SCRAPE=true`;
- `cron-scrape-sources=false` and `cron-cleanup-stale=false` in one transaction;
- `scrape` and `scrape.dlq` are installed with the hourly scrape and 30-minute cleanup schedules;
- controlled scrape and cleanup runs succeeded, the drain chain completed, and no scrape DLQ work remained;
- `CUTOVER_TAG=true`;
- `cron-tag-queue=false` and `cron-enrich-events=false` in one transaction;
- controlled and scheduled tag/enrichment runs succeeded after OpenAI and Unsplash credential smokes, and no tag DLQ work remained;
- `CUTOVER_REVIEW=true` with batch size 60;
- `cron-review-events=false`;
- the exact `gpt-5.4-mini` JSON-mode request passed, a single prioritized draft review completed with consistent queue/event/trace state, and eight catch-up runs drained the 377-row eligible backlog without failures or review DLQ work.

`CUTOVER_DIGEST`, `CUTOVER_REMINDERS`, and `CUTOVER_NOTIFY` remain disabled. They require delivery credentials and identified controlled recipients before their first production sends. The former Railway cron services have zero running replicas. Database maintenance remains outside the Nest job families.
