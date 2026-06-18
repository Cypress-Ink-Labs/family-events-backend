# Plan 018 (spike): Design a public read REST API for events

> **Executor instructions**: This is a DESIGN spike — the deliverable is a written design doc + a small
> proof-of-concept, NOT a full API. Do not build all endpoints. Record decisions and open questions.
> Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/share-og supabase/functions/sitemap supabase/migrations`

## Status

- **Priority**: P3
- **Effort**: L (design + PoC)
- **Risk**: — (design); the eventual build adds public attack surface — that's what the design must address
- **Depends on**: none (but compose with 016 iCal/RSS and 017 semantic-search — same public surface)
- **Category**: direction
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters (product)

Event data is currently reachable only through the app's own PostgREST calls. A documented public read API
(list/search/get events, by city/date/tag) would let partners — local news, parent blogs, community
calendar aggregators — build on the data instead of scraping it, increasing reach and partnership surface.
Grounding: the repo already serves public HTTP over its RPC layer (`share-og`, `sitemap`), and a rich
published-event RPC surface exists (`events_enriched`/`events_enriched_v2`, `search_events` with radius
filter, `find_similar_events_by_id`). The API is mostly a thin, documented, rate-limited façade over work
that's done.

## Current state (assets to build on)

- Public HTTP pattern: `share-og/index.ts` (public GET, UUID validation, cache headers, careful escaping),
  `sitemap/index.ts` (public GET, edge cache, XML). Both run `verify_jwt = false`.
- Published-event RPCs (read `supabase/migrations` for exact signatures): `public.search_events(...)`
  (filters: city, date range, age, free, featured, tags, keyword, pagination via
  `p_after_start_datetime`/`p_after_id` cursor), `events_enriched` / `events_enriched_v2`,
  `find_similar_events_by_id`. These already enforce published-only + grants.
- Registration: new functions need `config.toml` `verify_jwt` + `config/deploy.config.json`
  (`functions` + `noVerifyJwtFunctions`), enforced by `tests/guards/deploy-cli-boundary.test.mjs`.
- CORS allowlist module `_shared/cors.ts` (see plan 006) — a public API may want a *wider* CORS policy than
  the app allowlist (public read API ≈ open GET), a decision to make explicitly.

## Steps (produce a design doc, then a PoC)

### Step 1: Write `supabase/docs/PUBLIC_API.md` covering the design decisions
- **Endpoints (v1, read-only)**: `GET /events` (list/search → maps to `search_events`),
  `GET /events/:id` (→ `events_enriched_v2` / `share-og`-style lookup), optionally
  `GET /events/:id/similar` (→ `find_similar_events_by_id`, composes with plan 017),
  `GET /cities`. Keep it read-only for v1 (no writes — admin write API is a separate, higher-risk effort).
- **Auth model**: decide between fully anonymous public GET (simplest; matches `sitemap`/`share-og`) vs.
  API keys (needed only if you want per-partner rate limits / analytics). Recommend: anonymous + per-IP
  rate limiting for v1; API keys as a follow-up. Record rationale.
- **Pagination**: reuse `search_events`'s existing cursor (`p_after_start_datetime` + `p_after_id`) — expose
  it as opaque `cursor` tokens. Define the JSON envelope (`{ data: [...], next_cursor: "..." }`).
- **Rate limiting**: pick a mechanism (edge-level, or the Postgres-token approach sketched in plan 011).
  Define limits. Record.
- **Versioning + stability**: path prefix `/v1/`; document the deprecation policy. The response shape
  becomes a contract — list which `events` columns are public-safe (exclude internal LLM/review fields).
- **CORS**: decide the public policy (likely permissive GET) and how it differs from `_shared/cors.ts`.
- **Surface safety**: confirm every RPC the API exposes is published-only + grant-scoped (don't expose
  admin/`private` RPCs); list input validation per param.

### Step 2: Build a PoC for ONE endpoint
Implement `GET /events` only, as an edge function (`public-api` or `events-api`), thin over `search_events`:
- Parse + validate query params (city, date range, tags, keyword, limit, cursor) — reject malformed input
  with 400 (model validation on the careful patterns in `share-og`).
- Call the RPC, shape the public JSON envelope, set cache headers.
- Register the function (config.toml + deploy.config.json); add a unit test for param validation + envelope.

### Step 3: Record open questions
API-key store? Analytics/quotas? OpenAPI spec generation? Write-API later? List them in `PUBLIC_API.md`.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Typecheck | `pnpm run check` | exit 0 |
| Guards | `pnpm run workspace:test` | deploy-cli + auth-config guards pass (PoC function registered) |
| Function tests | `deno test` / `pnpm -C supabase/functions exec vitest run` | PoC validation tests pass |
| Serve + curl | `pnpm run db:functions:serve` then curl `/events?city=...&limit=5` | JSON envelope |

## Deliverable / Done criteria

- [ ] `supabase/docs/PUBLIC_API.md` with endpoints, auth model, pagination, rate-limit, versioning, CORS,
      and surface-safety decisions
- [ ] A working `GET /events` PoC over `search_events` with param validation + JSON envelope + cache headers
- [ ] PoC function registered; guard tests pass; `pnpm run check` exits 0
- [ ] Param-validation unit test passes
- [ ] Open questions recorded
- [ ] `plans/README.md` row for 018 updated

## STOP conditions

- `search_events` doesn't expose a column the API needs without also leaking internal fields — record
  which fields are missing/over-exposed; propose a dedicated public RPC rather than widening an internal one.
- Rate limiting can't be done at the edge without infra not present in this repo — document the constraint
  and ship the PoC behind a "no rate limit yet — do not announce publicly" note.

## Maintenance notes

- This is a design spike: ONE endpoint + a doc, not a full API. The doc is the primary artifact; the PoC
  proves the pattern.
- Composes with 016 (feeds) and 017 (similar events) — all three share the public read surface; design
  CORS/caching/versioning once.
- Reviewer: the v1 contract (response shape) is the thing to get right — it's expensive to change after
  partners depend on it. Scrutinize which `events` columns become public.
