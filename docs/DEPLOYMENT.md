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

## Scheduled reminders and digest (staged)

Both scheduled reminders and weekly digest queue `expireInSeconds = 43200` (12 hours) with no retries. That budget reconciles queue TTL with bounded batch duration. For 1,000 recipients and two serial 10-second provider calls each, the total budget is 20,000 seconds, plus 29.7 seconds of reminder pacing (batches of 10, 300ms each) or 99.5 seconds of digest pacing (batches of 5, 500ms each). These bounds fit below 12 hours and the 24-hour reminder interval. Database work and additional push subscriptions add runtime.

Reminders process batches of 10 recipients with a 300ms delay between batches. Digests process batches of 5 with a 500ms delay between batches, counting empty-plan users and continuing across 1,000-row page boundaries. Neither flow delays after its last batch.

Each channel fails independently. Reminder in-app rows use stable IDs and upsert counts. One push context caches subscriptions and credentials throughout the run.

Job cancellation propagates through queue handlers, batch pacing, Resend, Web Push, FCM delivery/OAuth, Telegram delivery, and Vault credential lookups, combined with each provider's 10-second timeout. Cancellation fails the run instead of reporting completion.

The scheduled digest lazily resolves its validated, Vault-first Telegram token at the first Telegram recipient, caching that result for the run. Email-only runs do not look up Telegram credentials. Vault query waiting is bounded to 2 seconds; timeout or database failure permits the environment fallback, while job cancellation propagates. The service retains its five-minute token cache. Missing or invalid tokens are not cached; a transient Vault failure permits the environment fallback.

Push delivery deduplicates and chunks recipient lookups at 1,000 IDs, continues after a failed lookup chunk, and reports `failedBatches`/`failedBatchRecipients` separately from subscription delivery failures. Complete Web Push and FCM JSON payloads are bounded to 3,000 UTF-8 bytes without splitting Unicode code points.
