# Plan 028 (SPIKE): Specify the 3 unbuilt public REST API endpoints

> **Executor instructions**: This is a SPIKE — investigate and produce a build
> spec + verify feasibility against the live code/RPCs. Do NOT build all three
> endpoints. Follow the steps; STOP conditions halt you. Update `plans/README.md`
> when done.
>
> **Drift check (run first)**:
> `git diff --stat 5daa274..HEAD -- supabase/functions/events-api supabase/docs/PUBLIC_API.md`

## Status

- **Priority**: P3
- **Effort**: M (spike)
- **Risk**: LOW (design output; at most ONE endpoint built as proof)
- **Depends on**: plan 024 (the `/{id}/similar` endpoint is blocked until the semantic-search wrapper is SECURITY DEFINER)
- **Category**: direction
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

`supabase/docs/PUBLIC_API.md` (and the plan 018 design) specify a read-only public
API: `GET /events` is BUILT (`events-api` PoC); `GET /events/{id}`,
`GET /events/{id}/similar`, and `GET /cities` are designed but unbuilt. Partners
(calendar aggregators, community sites) can list events but can't fetch one or
discover related/city data. The design is done; this spike turns it into a
build-ready spec, verifies each endpoint's backing RPC/query actually exists and
is callable at the intended privilege, and flags blockers — so the eventual build
is mechanical.

## Current state

- `supabase/functions/events-api/index.ts` — the PoC: param validation
  (`parseParams` → `{ok,...}`), cursor encoding, CORS, caching for `GET /events`.
  Read it as the pattern to replicate.
- `supabase/docs/PUBLIC_API.md` — specs for all four endpoints (validation rules,
  response shape, RPC mapping) + a rate-limiting section (see plan 029).
- `GET /events/{id}/similar` maps to `find_similar_events_by_id`, which is blocked
  for `anon` until plan 024 lands (`docs/SEMANTIC_SEARCH.md:71-104`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `pnpm run check` | exit 0 (if any code is touched) |
| Lint | `pnpm run lint` | exit 0 |
| Deno tests | `pnpm run test:deno` | pass |
| Grep RPCs in migrations | `grep -rn "<rpc_name>" supabase/migrations` | confirm existence |

## Scope

**In scope**:
- `supabase/docs/PUBLIC_API.md` — update each unbuilt endpoint's section with a
  verified build spec: exact backing RPC/query (confirmed to exist + callable at
  `anon`/`service_role`), request validation, response projection, caching headers,
  and a test checklist. Mark which are ready vs blocked.
- OPTIONAL proof: build the single simplest endpoint, `GET /events/{id}`, in
  `events-api` following the PoC pattern, WITH a Deno test — only if its backing
  read is confirmed and it fits the existing routing cleanly. Do NOT build
  `/{id}/similar` (blocked by 024) or `/cities` in this spike.

**Out of scope**: rate limiting (plan 029); building `/{id}/similar` and `/cities`
(future plans, informed by this spec); auth/write endpoints.

## Git workflow

- Branch: `advisor/028-spike-public-api-endpoints`
- Conventional Commits, e.g. `docs(api): spec the unbuilt public endpoints (+ GET /events/{id})`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Verify backing data paths
For each of `GET /events/{id}`, `/{id}/similar`, `/cities`: confirm the RPC/view
it reads exists in `supabase/migrations` and is callable by `anon` (grep the
function + its GRANTs). Record the exact name + signature. Note `/{id}/similar`
is blocked until plan 024.
**Verify**: each endpoint's backing path is named + its existence confirmed (or marked missing).

### Step 2: Write the per-endpoint build spec in PUBLIC_API.md
For each endpoint: request params + validation rules (reuse `events-api`'s
`parseParams` style), the RPC/query call, response projection (published fields
only), cache headers, error cases, and a test checklist. Mark `/{id}/similar`
"blocked on plan 024".
**Verify**: `PUBLIC_API.md` has a ready-to-implement spec section per endpoint.

### Step 3 (OPTIONAL proof): implement `GET /events/{id}`
Only if Step 1 confirmed a clean backing read. Follow the `events-api` PoC
(validation → RPC/query → projection → CORS → cache). Add a Deno test
(`events-api/*_test.ts`) for valid id, not-found, and bad-id.
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read events-api/` → pass; `pnpm run lint` + `pnpm run check` → 0.

## Test plan

- If Step 3 is done: Deno tests for `GET /events/{id}` (found / 404 / invalid id),
  pattern `events-api/events-api_test.ts`.
- Otherwise: no code tests; the deliverable is the verified spec.

## Done criteria

- [ ] PUBLIC_API.md has a verified, build-ready spec for each of the 3 endpoints, each citing its confirmed backing RPC/query + privilege, with `/{id}/similar` marked blocked-on-024
- [ ] Any RPC named as missing is flagged as a prerequisite
- [ ] If the optional `GET /events/{id}` was built: it has passing Deno tests and `check`/`lint` are 0
- [ ] `plans/README.md` status row updated (note follow-up build plans for `/{id}/similar` after 024, and `/cities`)

## STOP conditions

- A backing RPC/view for an endpoint does not exist — record it as a prerequisite and STOP building that endpoint (spec only).
- Building `GET /events/{id}` would require changing the events-api routing/auth posture in a non-obvious way — leave it spec-only and report.

## Maintenance notes

- `/{id}/similar` becomes buildable once plan 024 lands; this spec should make
  that a small follow-up. `/cities` likewise.
- Reviewer: confirm projections expose only published/public fields (no draft/admin columns) and validation matches the PoC.
