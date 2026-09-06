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

The reminder and digest notification flows use pg-boss queues with scheduled triggers. They are guarded by the [feature-flag families system](../README.md#feature-families) because they replace legacy cron jobs; the flag-flip retains the queue but sends nothing until the corresponding legacy cron is disabled.

### Environment variables

| Variable | Required? | Notes |
| --- | --- | --- |
| `RESEND_API_KEY` | yes | Works in development when rate limited or against the dev domain. |
| `TELEGRAM_BOT_TOKEN` | yes for Telegram digest | Vault value `telegram_bot_token` takes precedence over this environment fallback. Missing token or per-user chat ID skips only Telegram. |
| Web Push / FCM credentials | yes for reminder push | Use the VAPID and FCM variables or Vault names listed above. Missing provider credentials skip only that provider. |

Active U30 channels are reminder email, in-app, Web Push, and FCM; weekly digest email and Telegram; and event-change email, in-app, Web Push, and FCM. Both iOS and Android use FCM registration tokens. Only direct APNs delivery is deferred.

Scheduled reminders use deterministic batches of 10 with a 300ms abortable delay between batches. Digests use batches of 5 with a 500ms abortable delay between batches, counting empty-plan users and continuing across 1,000-row page boundaries. Neither flow delays after its last batch. Each channel fails independently. Reminder in-app rows use stable IDs and upsert counts; one push context caches subscriptions and credentials throughout the run.

Both scheduled queues explicitly set and reconcile `expireInSeconds = 43200` (12 hours), with no retries. For 1,000 recipients and two serial 10-second provider calls each, the provider budget is 20,000 seconds, plus 29.7 seconds of reminder pacing or 99.5 seconds of digest pacing. These bounds fit below 12 hours and the 24-hour reminder interval; database work and additional push subscriptions add runtime. Job cancellation propagates through queue handlers, pacing, Resend, Web Push, FCM delivery/OAuth, and Telegram, combined with each provider's 10-second timeout. Cancellation fails the run instead of reporting completion.

The scheduled digest lazily resolves its validated, Vault-first Telegram token at the first Telegram recipient, caching that result for the run. Email-only runs do not look up Telegram credentials. Vault query waiting is bounded to 2 seconds; timeout or database failure permits the environment fallback, while job cancellation propagates. The service retains its five-minute token cache; missing or invalid tokens are not cached. A transient Vault failure permits the environment fallback. Push delivery deduplicates and chunks recipient lookups at 1,000 IDs, continues after a failed lookup chunk, and reports `failedBatches`/`failedBatchRecipients` separately from subscription delivery failures. Complete Web Push and FCM JSON payloads are bounded to 3,000 UTF-8 bytes without splitting Unicode code points.

Operator checklist before flipping a flag:

1. Confirm the Resend hosted template `family-events-event-reminder` exists.
2. Confirm Vault credentials for VAPID, FCM, and Telegram (production) or environment credentials (development). In Vault, write `telegram_bot_token`, `vapid_public_key`, `vapid_private_key`, and `fcm_service_account_json`.
3. Test that the scheduled flow respects the feature flag in a dev environment.
4. Manually invoke the test-email flow with the internal `test` task and your own user email. The [digest-queue handler](../src/notifications/digest-queue.service.ts) handles `{ "task": "test", "testEmail": "you@example.com" }`. Manual `test` jobs bypass only the schedule-ownership gate; the address must belong to a user with `digest_email = true`. Test-email jobs are intentionally email-only and never resolve a Telegram token, send to a stored Telegram chat, or apply scheduled batch delays.
5. Disable the matching legacy cron through the U33 atomic handoff, then watch the first scheduled run summary. Repeat independently for reminders.