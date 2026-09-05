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

## Required environment variables

The API requires the following environment variables. Sensitive keys are stored
in Supabase Vault (`vault.decrypted_secrets`) with environment-variable fallbacks
noted below. Railway service variables override `.env`. Set every variable in
the production Railway service and every local `.env`, matching the scope notes.

| Key | Required? | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | yes | Supabase Postgres URI with pooling; Railway injects it, local devs grab it from Supabase dashboard. |
| `CUTOVER_SCRAPE` / `CUTOVER_TAG` / `CUTOVER_REVIEW` / `CUTOVER_DIGEST` / `CUTOVER_REMINDERS` / `CUTOVER_NOTIFY` | yes | Job family toggles (exact string `"true"` enables); see cutover checklists. |
| `RESEND_API_KEY` / `RESEND_FROM` / `APP_URL` | yes | Email delivery (Resend) and app-URL fragments for notification and digest links. |
| `SUPABASE_SERVICE_ROLE_KEY` | yes | Supabase service-role JWT; Railway injects it, local `.env` needs it for `pnpm dev`. |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | yes | Public project URL + anon JWT (legacy service uses both; API-only needs `SUPABASE_URL`). Railway injects them. |
| `VAPID_PRIVATE_KEY` / `VAPID_PUBLIC_KEY` / `VAPID_SUBJECT` | required for web push | Environment fallback for Web Push credentials. Vault names `vapid_private_key`, `vapid_public_key`, and `vapid_subject` take precedence. |
| `FCM_SERVICE_ACCOUNT_JSON` | required for mobile push | JSON service account fallback for FCM HTTP v1. Both iOS and Android subscription tokens use FCM. Vault name `fcm_service_account_json` takes precedence. |
| `AI_PROVIDER` / `AI_BASE_URL` / `AI_MODEL` / `AI_API_KEY` / `OPENAI_API_KEY` | no | LLM extraction fallback, tagging, review, and embeddings (`src/pipeline/llm-config.ts`; `OPENAI_API_KEY` also read directly by tag-event embeddings). Unset leaves LLM paths unconfigured. |
| `UNSPLASH_ACCESS_KEY` / `PEXELS_API_KEY` / `PIXABAY_API_KEY` | no | Stock-image enrichment (U29); unset providers are skipped in fallback order. Unsplash key is shared by search, download tracking, and attribution backfill. |
| `SCRAPER_IMAGE_HOST_ALLOWLIST` | no | Comma-separated extra ingest image hosts appended to the built-in CDN allowlist. |
| `NODE_VERSION` | yes | `22` — Railway service variable, not a `.env` entry. |

Note: the `AI_*`, stock-image, and allowlist variables are read through
the pipeline's `process.env` seams noted below. `.env.example` mirrors both.

## Cutover checklists

### Scrape, tag, review families

These replace the Railway `cron-scrape-sources`, `cron-tag-events`, and
`cron-review-events` services (five-minute, ten-minute, and hourly schedules).

Operator checklist before flipping a flag:

1. Confirm the API Railway service is deployed with `CronGateService` and every
   job family worker present. The gate reads `private.cron_enabled` labels, so
   the API must be fully online before the first toggle.
2. Set the relevant `CUTOVER_*="true"` environment variable and redeploy. The
   API schedules the job; `CronGateService` checks the legacy label at runtime.
3. Observe one gated run (skipped with `legacy still owns schedule` log).
4. Disable the legacy cron through the Railway dashboard or mark
   `private.cron_enabled = false` for the matching label (exact labels at
   `docs/plans/2026-08-16-002-nestjs-backend-rewrite-plan.md`).
5. The next run processes normally. Verify logs, run counts, and
   `private.cron_runs` history for success/failure under the new label.
6. Once stable, archive or delete the Railway service.

### Digest family

`CUTOVER_DIGEST="true"` schedules a daily job that replaces
`cron-send-daily-digest`. Follow the same five-step handoff above, but wait at
least 24 hours between observing the first gated skip and disabling the legacy
cron, then confirm the `yesterday` calculation and that only users opted in
with `digest_email = true` receive email.

### Reminders family

`CUTOVER_REMINDERS="true"` schedules two jobs (hourly and daily) that replace
`cron-send-reminders`. Follow the same handoff pattern, but monitor two separate
schedules (`reminders-hourly` and `reminders-daily`) and confirm filtering to users
with `digest_email = true`.

### Notify family (event-change notifications)

`CUTOVER_NOTIFY="true"` installs an internal five-minute pg-boss schedule. It does not
replace a Railway cron and does not use `CronGateService`. The existing
`public.notification_queue` table remains the durable one-hour debounce buffer.
When the flag is off, bootstrap removes the durable `process-notification-queue`
schedule if a prior deployment installed it. The runtime handler also rejects
work while the flag is off.

Checklist before setting `CUTOVER_NOTIFY="true"`:

1. Confirm the existing notification queue, preference, in-app notification,
   and push subscription tables are deployed. No new API migration is required.
2. Create the Resend hosted template `family-events-event-change`, then set
   `RESEND_API_KEY`, a verified `RESEND_FROM`, and `APP_URL`.
3. Confirm every `ios` and `android` row in `public.push_subscriptions` contains
   a current FCM registration token. Direct APNs tokens are not supported.
4. Confirm stored Web Push endpoints use HTTPS and one of the trusted provider
   hosts: `fcm.googleapis.com`, `updates.push.services.mozilla.com`,
   `web.push.apple.com`, or a subdomain of `notify.windows.com`.
5. Add Web Push and FCM credentials to `vault.decrypted_secrets`, or set the
   environment fallback variables listed above. Missing provider credentials
   soft-skip only that provider.
6. Set `CUTOVER_NOTIFY="true"` and redeploy. Confirm `notify`, `notify.dlq`, and
   one `process-notification-queue` schedule exist with concurrency 1 and no retries.
7. Do not create or disable a `private.cron_enabled` label for notify. Monitor the
   first run counts, lock skips, refreshed rows, unmatched push recipients, and
   any `persistenceFailed` result.

Direct APNs delivery remains deferred until the schema has a provider
discriminator and existing tokens have been migrated. Reminder push and in-app
delivery, plus Telegram digest delivery, also remain deferred.
