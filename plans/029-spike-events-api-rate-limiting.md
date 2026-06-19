# Plan 029 (SPIKE): Choose and design per-IP rate limiting for the public events-api

> **Executor instructions**: This is a SPIKE — evaluate options and produce a
> recommendation + design, NOT a production implementation. Follow the steps;
> STOP conditions halt you. Update `plans/README.md` when done.
>
> **Drift check (run first)**:
> `git diff --stat 5daa274..HEAD -- supabase/functions/events-api supabase/docs/PUBLIC_API.md`

## Status

- **Priority**: P3
- **Effort**: M (spike)
- **Risk**: LOW (design output; no production rate-limiter shipped in this plan)
- **Depends on**: none (but gates any public announcement of the API)
- **Category**: direction
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

`events-api` carries an explicit TODO: "no rate limiting — do not announce this
endpoint publicly until per-IP rate limiting is implemented"
(`supabase/functions/events-api/index.ts` top comment), and `PUBLIC_API.md`
documents the gap with three candidate approaches. Until this is decided +
implemented, the public API stays officially undiscoverable. This spike picks the
approach and produces a concrete, build-ready design so a follow-up plan can ship
it.

## Current state

- `supabase/functions/events-api/index.ts:4-6` — the no-rate-limit TODO.
- `supabase/docs/PUBLIC_API.md` (rate-limiting section) — lists 3 options:
  1. **Upstash Redis** (sliding window; new external service + credentials),
  2. **Postgres token-bucket** (an RPC/table; adds DB latency per request; the
     pattern plan 011 sketched for Nominatim),
  3. **Cloudflare WAF** (infra layer, not an edge-function change).
  Target documented: ~100 req/min per IP, burst ~200.
- Constraint: edge functions are stateless across invocations (no shared
  in-memory counter that survives), and run behind Supabase's platform — the
  client IP must be read from the forwarded header (verify which:
  `x-forwarded-for` / `cf-connecting-ip`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Lint (if any code touched) | `pnpm run lint` | exit 0 |
| Typecheck | `pnpm run check` | exit 0 |
| Grep IP header usage | `grep -rn "x-forwarded-for\|cf-connecting-ip\|forwarded" supabase/functions` | see what's available |

## Scope

**In scope**:
- A decision doc: `supabase/docs/RATE_LIMITING.md` (create) — compare the 3
  options against THIS deployment (Supabase edge + Railway), each with: how it
  works here, latency cost, new infra/secrets, failure mode (fail-open vs
  fail-closed), and operability. End with a clear RECOMMENDATION + a build-ready
  design for the chosen option (data model / API, where the check goes in
  `events-api`, the limit + headers `Retry-After`/`X-RateLimit-*`, fail-open
  policy, and a test plan).
- Determine + document the correct client-IP source header for this platform.
- OPTIONAL: a thin, behind-a-flag proof in `events-api` ONLY if it is zero-risk
  and clearly the chosen design (e.g. the Postgres token-bucket RPC scaffold,
  disabled by default) — otherwise leave implementation to the follow-up plan.

**Out of scope**: shipping the production rate limiter enabled by default;
provisioning Upstash/Cloudflare; announcing the API.

## Git workflow

- Branch: `advisor/029-spike-events-api-rate-limiting`
- Conventional Commits, e.g. `docs(api): rate-limiting options + recommendation (spike)`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Establish the client-IP source
Find how (and whether) edge functions can read the real client IP in this
deployment (forwarded header). If it is not reliably available, that constrains
the options (e.g. forces the Cloudflare/infra layer) — record it.
**Verify**: the IP-source mechanism is documented (or its absence noted as a constraint).

### Step 2: Compare the three options
In `RATE_LIMITING.md`, evaluate Upstash / Postgres token-bucket / Cloudflare for
this stack on: latency added per request, new infra + secrets, fail-open vs
fail-closed under outage, multi-region correctness, and operational burden.
Ground each against repo reality (plan 011's degrade-on-429 precedent; the
stateless edge runtime).
**Verify**: a comparison table + a single recommendation with rationale.

### Step 3: Build-ready design for the chosen option
Specify: where the check sits in `events-api` request flow, the limit/window
(100/min, burst 200 per the doc — confirm or adjust), the data model/API (e.g.
token-bucket table + RPC, or Upstash key shape), response on limit
(`429` + `Retry-After` + `X-RateLimit-*`), the fail-open policy, env/secrets
needed, and a test plan. List open questions for the follow-up build plan.
**Verify**: the design section is detailed enough to implement without re-deciding.

### Step 4 (OPTIONAL, zero-risk only): scaffold disabled-by-default
Only if the chosen design has a safe, inert scaffold (e.g. an unused RPC migration
+ rollback, or a flag-gated no-op check). If anything would alter live request
handling, SKIP and leave to the follow-up.
**Verify**: if done, `pnpm run check`/`lint` → 0 and `pnpm run workspace:test` passes (any migration has a paired rollback).

## Test plan

- Spike output is a doc; no production tests required. If Step 4 ships a migration
  scaffold, it needs a paired rollback (guard-enforced) and must be inert.

## Done criteria

- [ ] `supabase/docs/RATE_LIMITING.md` exists with the 3-option comparison + a single recommendation
- [ ] The client-IP source for this platform is documented (or its absence flagged as a constraint)
- [ ] A build-ready design for the chosen option (limit, data model/API, 429 + headers, fail-open, secrets, test plan, open questions)
- [ ] Any optional scaffold is inert + (if a migration) has a paired rollback; `workspace:test` green
- [ ] `plans/README.md` status row updated (note the follow-up "implement rate limiting" plan)

## STOP conditions

- The real client IP is not reliably available to edge functions AND no option works without it — record that the limiter must live at the Cloudflare/infra layer and STOP (the decision is then an infra one, not an edge-function change).
- Any step would require enabling a live rate limiter or provisioning paid infra — STOP; that's the follow-up build plan, not this spike.

## Maintenance notes

- This unblocks a public announcement of the API (and pairs with plan 028's
  endpoint build-out). The follow-up build plan implements the recommendation.
- Reviewer: scrutinize the fail-open policy (a rate limiter that fails closed can
  take the public API down if its backing store is unavailable).
