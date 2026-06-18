# Plan 002: `.env.example` documents every environment variable the code reads

> **Executor instructions**: Follow step by step; run every verification command. Honor STOP
> conditions. Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- .env.example supabase/functions`
> If function code changed, re-run the discovery grep in Step 1 (it is the source of truth, not the
> list below).

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW (documentation only; `.env.example` is the sole file touched)
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

`.env.example` documents **6** variables. The edge functions actually read **~28** distinct
configuration variables via `Deno.env.get(...)`. A developer (or a fresh deploy) following
`.env.example` will hit runtime failures ("X not configured") or silent wrong-default behavior
(e.g. AI review quietly disabled, push silently no-op) for everything undocumented. This is the
single cheapest onboarding + misconfiguration fix in the repo.

## Current state

`.env.example` today (entire file):

```
# Supabase
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key

# Email (Resend)
RESEND_API_KEY=re_your-api-key

# Railway (cron + infra)
RAILWAY_TOKEN=your-railway-token

# GitHub Packages (read:packages PAT for consuming @family-events/* npm packages)
NODE_AUTH_TOKEN=ghp_your-pat
```

The full set of keys read by `supabase/functions/**` (from `grep -rhoE 'Deno\.env\.get\("[A-Z0-9_]+"\)'`):

```
ADMIN_NOTIFY_EMAIL AI_API_KEY AI_BASE_URL AI_MODEL AI_PROVIDER ALLOWED_ORIGINS
APNS_BUNDLE_ID APNS_ENVIRONMENT APNS_KEY_ID APNS_PRIVATE_KEY APNS_TEAM_ID APP_URL
DUE_SOURCE_LIMIT FCM_SERVICE_ACCOUNT_JSON LLM_REVIEW_BATCH_SIZE OPENAI_API_KEY OPENAI_MODEL
OPENWEATHER_API_KEY PEXELS_API_KEY PIXABAY_API_KEY RESEND_API_KEY RESEND_FROM RESEND_REPLY_TO
SB_EXECUTION_ID SB_REGION SEND_EMAIL_HOOK_SECRET SENTRY_DSN SENTRY_TRACES_SAMPLE_RATE
SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY SUPABASE_URL UNSPLASH_ACCESS_KEY
VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY VAPID_SUBJECT
```

`SB_EXECUTION_ID` and `SB_REGION` are **platform-injected by the Supabase edge runtime** — do not put
them in `.env.example`. `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` are also
auto-injected in deployed functions but are needed locally, so keep them (already present).
`.gitignore` already ignores `.env` / `.env.*` except `.env.example`, so this file is the right place.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Re-derive the live key list | `grep -rhoE 'Deno\.env\.get\("[A-Z0-9_]+"\)' supabase/functions/ \| grep -oE '"[A-Z0-9_]+"' \| sort -u` | the set above (re-check for drift) |
| Confirm a var's purpose | `grep -rn '"<VAR>"' supabase/functions` | shows the consuming function |

## Steps

### Step 1: Re-derive the authoritative list

Run the discovery grep (above). This is the source of truth — if it differs from the list in
"Current state", use the live output. Exclude `SB_EXECUTION_ID` and `SB_REGION` (platform-injected).

### Step 2: Rewrite `.env.example`, grouped by feature, each var commented

Produce a `.env.example` with sections like the sketch below. For each var, write a one-line comment
on what it does and whether it's **required** or **optional (feature flag / has default)**. To classify,
grep the consuming code (e.g. `RESEND_FROM` has a default in
`process-notification-queue/index.ts:162`; `AI_*` vs `OPENAI_*` are alternate LLM providers — see
`_shared/llm-config.ts` and `event-review/config.ts`). Target shape:

```
# ── Supabase (required; auto-injected in deployed functions, needed locally) ──
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key

# ── LLM provider (required for tagging/enrichment/review) ──
# Generic provider (Ollama/OpenAI-compatible). See supabase/docs/LOCAL_LLM_TAGGING.md
AI_PROVIDER=
AI_BASE_URL=
AI_API_KEY=
AI_MODEL=
# OpenAI (used by embeddings + review when configured)
OPENAI_API_KEY=
OPENAI_MODEL=
LLM_REVIEW_BATCH_SIZE=
DUE_SOURCE_LIMIT=

# ── Email (Resend) ──
RESEND_API_KEY=re_your-api-key
RESEND_FROM=Family Events <onboarding@resend.dev>
RESEND_REPLY_TO=
ADMIN_NOTIFY_EMAIL=
SEND_EMAIL_HOOK_SECRET=

# ── Web Push (VAPID) ──
VAPID_PUBLIC_KEY=
VAPID_PRIVATE_KEY=
VAPID_SUBJECT=

# ── Apple Push (APNs) ──
APNS_TEAM_ID=
APNS_KEY_ID=
APNS_PRIVATE_KEY=
APNS_BUNDLE_ID=
APNS_ENVIRONMENT=
# ── Firebase Cloud Messaging ──
FCM_SERVICE_ACCOUNT_JSON=

# ── Stock image providers (optional fallback chain) ──
PEXELS_API_KEY=
PIXABAY_API_KEY=
UNSPLASH_ACCESS_KEY=

# ── Weather ──
OPENWEATHER_API_KEY=

# ── Observability (optional) ──
SENTRY_DSN=
SENTRY_TRACES_SAMPLE_RATE=

# ── App / CORS ──
APP_URL=https://family-events.up.railway.app
ALLOWED_ORIGINS=

# ── Infra / packages ──
RAILWAY_TOKEN=your-railway-token
NODE_AUTH_TOKEN=ghp_your-pat
```

Do not invent values — leave secrets blank (`KEY=`) and only fill placeholders that are non-secret
defaults already visible in code (e.g. `RESEND_FROM`, `APP_URL`).

**Verify**: every key from the Step-1 list (minus `SB_EXECUTION_ID`, `SB_REGION`) appears in
`.env.example`:

```
comm -23 \
  <(grep -rhoE 'Deno\.env\.get\("[A-Z0-9_]+"\)' supabase/functions/ | grep -oE '[A-Z0-9_]+' | sort -u | grep -vE '^(SB_EXECUTION_ID|SB_REGION)$') \
  <(grep -oE '^[A-Z0-9_]+' .env.example | sort -u)
```
→ prints **nothing** (empty diff = every consumed var is documented).

## Done criteria

- [ ] The `comm` diff above prints nothing
- [ ] No secret *values* are written into `.env.example` (only blank keys or non-secret defaults)
- [ ] Only `.env.example` changed (`git status`)
- [ ] `plans/README.md` row for 002 updated

## STOP conditions

- The drift check shows function code changed and the live grep yields keys not covered by this plan's
  guidance — document the new keys, classify them, then proceed (this is expected maintenance, not a blocker).
- A var you cannot classify as required vs optional from the code — mark it `# (purpose unclear — verify)`
  rather than guessing, and note it in your report.

## Maintenance notes

- Consider a follow-up guard test (node:test, like the others in `tests/guards/`) that fails when a
  `Deno.env.get("X")` key is missing from `.env.example` — that would keep this from drifting again.
  Deferred out of this plan to keep it documentation-only.
