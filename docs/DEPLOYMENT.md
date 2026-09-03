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

## Notifications (email, staged)

In production, queues register only when their cutover flags are exactly
`"true"`: `CUTOVER_REMINDERS` and `CUTOVER_DIGEST`. Scheduled handlers also
pass through the atomic `private.cron_enabled` gate, so setting a flag installs
the queue but sends nothing until the corresponding legacy cron is disabled.

| Variable | Required when enabled | Notes |
| --- | --- | --- |
| `RESEND_API_KEY` | yes | Resend key. Unset means all email soft-fails (logged as `sent: false, dev: true`); jobs still complete without retry. |
| `RESEND_FROM` | recommended | Default `Family Events <onboarding@resend.dev>` is a sandbox sender; replace it with a verified domain for production. |
| `APP_URL` | recommended | Default `https://family-events.up.railway.app`; used for event, logo, browse, and preference links. |

Operator checklist before flipping a flag:

1. Confirm the Resend hosted template `family-events-event-reminder` exists.
   Legacy templates were deployed outside the repository, so recreate it if
   needed. The weekly digest uses raw HTML and needs no hosted template.
2. Set `RESEND_FROM` to a verified Resend domain.
3. Set `CUTOVER_DIGEST="true"` and redeploy to install the queue, but leave the
   legacy digest cron enabled. Scheduled `send` jobs remain blocked by the
   ownership gate.
4. Submit a one-recipient job through the pg-boss dashboard or SQL:
   `{ "task": "test", "testEmail": "you@example.com" }`. Manual `test` jobs
   bypass only the schedule-ownership gate; the address must belong to a user
   with `digest_email = true`.
5. Disable the matching legacy cron through the U33 atomic handoff, then watch
   the first scheduled run summary. Repeat independently for reminders.
