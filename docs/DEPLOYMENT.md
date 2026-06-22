# Deployment

How `family-events-backend` reaches production.

## What deploys, and how

| Artifact | Mechanism | Gate |
| --- | --- | --- |
| **DB migrations + edge functions** | GitHub Actions `deploy.yml` → `family-events-deploy` CLI | runs after `ci` succeeds on `main`, then waits on the **`production`** GitHub Environment for one-click approval |
| **Railway services** (`cron-*` here; `web` in the web repo) | Railway's GitHub integration | see [Railway gating](#railway-gating) |
| **`@cypress-ink-labs/contracts`** package | `publish-packages.yml` | publishes on push to `main` that bumps `packages/contracts/{src,package.json}` or `.changeset/**` |

`deploy.yml` runs only the Supabase side (`deploy supabase:migrations supabase:functions:all`) — Railway deploys are owned by Railway, so the CD never double-deploys them.

## GitHub Actions CD (`deploy.yml`)

1. `ci` passes on `main` (or you run `deploy.yml` via **workflow_dispatch**).
2. The `deploy-supabase` job pauses on the `production` environment until a required reviewer approves.
3. On approval it runs the deploy CLI, which: applies migrations (`supabase db push --linked --include-all`, auto-linking the project first) → deploys every edge function (`supabase functions deploy … [--no-verify-jwt]`) → runs a smoke probe.

### Required GitHub secrets

| Secret | Purpose |
| --- | --- |
| `SUPABASE_ACCESS_TOKEN` | Supabase management API (link + functions deploy) |
| `SUPABASE_PROJECT_REF` | Project ref (`ufrjcnozcapskjtoakvf`) |
| `SUPABASE_DB_PASSWORD` | DB password for `db push` / `link` (read from env by the Supabase CLI) |
| `SUPABASE_SERVICE_ROLE_KEY` | (existing) smoke probe |
| `RAILWAY_API_TOKEN` | (existing) Railway-side tooling |

## Manual / local deploy

```bash
# One-time: link the project
bash scripts/supabase.sh link --project-ref <ref>

# Deploy everything the CLI owns (migrations + functions + cron services)
pnpm run deploy:all
# …or just the Supabase side, or a dry run:
pnpm --filter @cypress-ink-labs/deploy-cli cli deploy supabase:migrations supabase:functions:all --yes
pnpm --filter @cypress-ink-labs/deploy-cli cli deploy --all --yes --dry-run
```

The CLI auto-links the project in CI when `SUPABASE_ACCESS_TOKEN` + `SUPABASE_DB_PASSWORD` are set, so no pre-link step is needed in the workflow.

## Railway gating

`web` and the `cron-*` services deploy through Railway's GitHub integration. To keep that gated on CI, see the web repo's `docs/DEPLOYMENT.md` and the project's Railway settings. <!-- finalized in CIL-190 -->

## Migration ordering (expand/contract)

CD pipelines for the two repos are independent, so **make schema changes backward-compatible** and deploy them **before** the code that depends on them:

- New columns/tables/RPCs are additive; old code keeps working without them.
- For a cross-repo change (e.g. a new RPC consumed by the web app), approve/deploy the **backend** `production` deploy **before** the web one. The approval gate makes the ordering explicit.
- Removals are a second, later change once nothing references the old shape.

This is why the web app must never ship code calling an RPC/column in the same release that introduces it — that caused a brief prod break before CD existed (see CIL-190).
