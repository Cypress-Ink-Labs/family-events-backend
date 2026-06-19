# Public Read API — Design Document (v1 spike)

> Status: **Design spike** (plan 018; build specs verified in plan 028). `GET /events` (list, PoC)
> and `GET /events/{id}` (single event) are **built**. `GET /events/{id}/similar` and `GET /cities`
> are specified with verified backing reads and **ready to build** (`/{id}/similar` was unblocked by
> plan 024). Open questions are recorded at the bottom.

## Overview

A thin, documented, read-only REST façade over the published-event data. Lets partners — local
news sites, parent blogs, community calendar aggregators — build on the data instead of scraping
it. The API is versioned at `/v1/` and backed by existing published-only RPCs (`search_events`,
`events_enriched_v2`, `find_similar_events_by_id`) that already enforce RLS and published-only
access via the anon key.

---

## Endpoints (v1, read-only)

### `GET /functions/v1/events-api` — List / search events (PoC BUILT)

Maps to `public.search_events(...)`.

**Query parameters:**

| Param       | Type                  | Default | Notes                                                              |
| ----------- | --------------------- | ------- | ------------------------------------------------------------------ |
| `city_id`   | UUID                  | —       | Filter by city                                                     |
| `date_from` | ISO 8601 datetime     | —       | Inclusive lower bound on `start_datetime`                          |
| `date_to`   | ISO 8601 datetime     | —       | Inclusive upper bound on `start_datetime`                          |
| `is_free`   | `true`/`false`        | —       | Free events only                                                   |
| `tags`      | comma-separated slugs | —       | All specified tags must match                                      |
| `keyword`   | string ≤ 100 chars    | —       | Full-text search                                                   |
| `limit`     | 1–100                 | 20      | Page size (capped at 100 for public API; RPC allows 500)           |
| `cursor`    | opaque string         | —       | Pagination cursor returned as `next_cursor` in a previous response |

**Response envelope:**

```json
{
  "data": [
    /* array of event objects */
  ],
  "next_cursor": "eyJhZnRlcl9zdGFydCI6Ii4uLiIsImFmdGVyX2lkIjoiLi4uIn0="
}
```

`next_cursor` is absent when there are no more results (`data.length < limit`).

**Public event object (v1 contract — columns we commit to):**

```json
{
  "id": "uuid",
  "title": "string",
  "description": "string | null",
  "start_datetime": "ISO 8601",
  "end_datetime": "ISO 8601 | null",
  "timezone": "string | null",
  "venue_name": "string | null",
  "address": "string | null",
  "city_id": "uuid | null",
  "latitude": "number | null",
  "longitude": "number | null",
  "age_min": "integer | null",
  "age_max": "integer | null",
  "price": "number | null",
  "is_free": "boolean",
  "is_featured": "boolean",
  "is_outdoor": "boolean | null",
  "images": "array of strings",
  "tags": [{ "id": "uuid", "name": "string", "slug": "string", "color": "string" }],
  "source_url": "string | null",
  "avg_rating": "number",
  "rating_count": "integer"
}
```

**Columns intentionally excluded from v1 (internal / LLM / admin fields):**

| Column                      | Reason                                               |
| --------------------------- | ---------------------------------------------------- |
| `search_vector`             | Internal tsvector, not useful to partners            |
| `ai_confidence`             | Internal LLM metadata                                |
| `ai_tag_provider`           | Internal LLM metadata                                |
| `parent_tips`               | User-facing only, not a partner contract yet         |
| `parent_tips_generated_at`  | Internal bookkeeping                                 |
| `view_count`                | Competitive intelligence risk                        |
| `source_id`                 | Internal FK; `source_url` + `source_name` are enough |
| `source_name`               | Included: helps partners cite origin                 |
| `recurrence_info`           | Unstable jsonb shape; recurrence is a follow-up      |
| `is_favorited`              | User-specific, always false for anon                 |
| `is_in_calendar`            | User-specific, always false for anon                 |
| `created_at` / `updated_at` | Internal bookkeeping                                 |

> **STOP condition note**: `search_events` returns `SETOF events` (the raw table), which includes
> internal columns (`ai_confidence`, `ai_tag_provider`, `search_vector`, etc.). The edge function
> **must** project only the public columns listed above — it must NOT proxy the full row. A dedicated
> public-only RPC would be cleaner long-term (open question below).

---

### `GET /functions/v1/events-api/{id}` — Single event (BUILT — plan 028 proof)

> **Status: BUILT.** Implemented in `events-api/index.ts` as `handleGetEvent`; routed off the
> trailing path segment. Verified by `events-api/events-api_test.ts`.

**Backing read (verified):** `public.events_enriched_v2(p_event_ids => ARRAY[id]::uuid[])`
— defined in migration `20260601006000_enrichment_images_and_rpc_cleanup.sql:435`,
`GRANT EXECUTE ... TO anon, authenticated, service_role` (same migration, line 542). The function
is `LANGUAGE sql STABLE` with **no `SECURITY` clause → SECURITY INVOKER**, so it runs with the
caller's privileges and the anon RLS policy on `public.events` applies.

**Why this is safe for anon despite the function's WHERE clause:** the `events_enriched_v2` body
gates `status = p_status` only on the `p_event_ids IS NULL` branch
(`20260601006000_...:525-530`). Operator precedence means the `p_event_ids` branch matches by id
alone and does **not** re-filter on status. The published-only guarantee therefore comes from RLS,
not the function: policy `"Anon can read published events" ON public.events FOR SELECT TO anon
USING (status = 'published')` (`20260601017000_...:131`). Called via the **anon key** (as this
function does), a draft/unpublished id returns zero rows → the handler emits **404**. Do NOT call
this RPC with the service-role key for this endpoint — that would bypass RLS and could leak drafts.

**Request:** path `…/events-api/{id}`. No query params. The single-event route only matches when the
trailing segment is a UUID (`events-api`'s `UUID_PATTERN`). A non-UUID single segment is treated as
an **unknown route → 404** (it is reserved for future named routes such as `cities`), not as a
malformed id — so the published-only behaviour never depends on a UUID round trip to Postgres.

**Response (200):** `{ "data": <PublicEvent> }` using the **same `projectEvent` projection** as the
list endpoint (published/public columns only; internal/LLM/admin/user-specific columns excluded —
see the exclusion table above).

**Errors:** `404 {"error":"event not found"}` (UUID with no visible row / not published /
RLS-filtered); `404 {"error":"not found"}` (non-UUID / unknown route); `405` for non-GET;
`503` if env is missing; `500 {"error":"query failed"}` on RPC error.

**Cache:** reuse `CACHE_CONTROL` (`public, max-age=60, s-maxage=60, stale-while-revalidate=30`) on
200; no cache header on 404 (so a just-published event is not pinned as missing at the edge).

**Test checklist (implemented in `events-api_test.ts`):**

- `parseRoute`: `…/events-api/<uuid>` → `{kind:"event"}`; bare collection path → `{kind:"list"}`;
  `cities`, a non-UUID segment, and `<id>/similar` → `{kind:"unknown"}` (so the single-event route
  does not shadow future routes).
- non-GET method → 405; unknown route → 404; missing env → 503 (all resolved before any DB call).

---

### `GET /functions/v1/events-api/{id}/similar` — Similar events (READY — unblocked by plan 024)

> **Status: READY to build** (was blocked; plan 024 has landed). Not built in plan 028 (out of scope).

**Backing read (verified):** `public.find_similar_events_by_id(p_event_id uuid, p_limit int,
p_city_id uuid)` — made `SECURITY DEFINER` and `GRANT EXECUTE ... TO authenticated, anon,
service_role` in migration `20260618000000_find_similar_events_by_id_security_definer.sql`
(plan 024). Before plan 024 the public wrapper was `SECURITY INVOKER` and anon hit
`42501 permission denied` reaching the `private` body — that was the blocker. **Now anon-callable.**

**Published-only guarantees (verified, defense in depth):** the private body
(`20260618000000_...:74-93`) looks up the source event's embedding **only when the source event is
`status = 'published'`** (an unpublished source id → no embedding → empty result), and filters the
returned neighbours to `status = 'published'` as well. So neither the source nor the neighbours leak
drafts even though embeddings exist for drafts.

**Shape note — a second hydration query is required.** `find_similar_events_by_id` returns only
`(event_id, title, status, cosine_distance, source_id, city_id)` — NOT the full public event
object. To return the list/`{id}` projection, the handler must:

1. Validate `{id}` (UUID regex → 400 on bad input) and optional `limit` (1–`MAX_LIMIT`, default a
   small value e.g. 5) / `city_id` (UUID).
2. Call `find_similar_events_by_id(p_event_id => id, p_limit => limit, p_city_id => city_id)` →
   ordered list of similar `event_id`s.
3. Hydrate full rows via `events_enriched_v2(p_event_ids => ARRAY[those ids])` **with the anon key**
   (RLS keeps it published-only), then re-order to match the cosine-distance order from step 2
   (`events_enriched_v2` orders by `start_datetime`, not similarity).
4. Project each row with `projectEvent`. Optionally surface `cosine_distance` as a `similarity`
   field (decide at build time; not part of the committed list projection).

**Response (200):** `{ "data": [ <PublicEvent>, … ] }`. An unknown / unpublished `{id}` yields
`{ "data": [] }` (empty, not 404 — the source is simply not visible / has no neighbours).

**Cache:** reuse `CACHE_CONTROL`.

**Test checklist (for the build plan):** valid id → ordered similar list; unpublished/unknown id →
empty `data`; bad UUID → 400; `limit` clamp; neighbour ordering preserved after hydration.

---

### `GET /functions/v1/events-api/cities` — City list (READY)

> **Status: READY to build.** Not built in plan 028 (out of scope).

**Backing read (verified):** direct table select on `public.cities`. No RPC needed.
`GRANT ALL ON TABLE public.cities TO anon` (`20260601000000_schema_baseline.sql:6645`) and RLS
policy `"Anon can read active cities" ON public.cities FOR SELECT TO anon USING (is_active = true)`
(`20260601000000_...:5507`). Anon, via the anon key, sees only active cities.

**Columns (verified against `cities` definition, `20260601000000_...:4321`):**
`id uuid`, `name text NOT NULL`, `state text` (**nullable**), `country text NOT NULL` (default
`'US'`), plus `slug`, `is_active`, `latitude`, `longitude`, `timezone`, `created_at`. Project the
public subset only.

**Request:** path `…/events-api/cities`. No query params (a `state` filter is a possible follow-up).

**Query:** `supabase.from("cities").select("id, name, state, country").eq("is_active", true)`
with the anon key. The `is_active` predicate is redundant with RLS but keeps intent explicit.
Order by `name` for a stable response.

**Response (200):** `{ "data": [ { "id": "uuid", "name": "string", "state": "string | null",
"country": "string" }, … ] }`. Note `state` is **nullable** — type it `string | null`, not `string`.

**Cache:** cities change rarely; a longer TTL is appropriate
(`public, max-age=3600, s-maxage=3600, stale-while-revalidate=300`) rather than the 60 s event TTL.

**Test checklist (for the build plan):** projection excludes non-public columns; `state` nullable
handled; only active cities returned (RLS); response sorted by `name`.

---

## Auth model

**v1 decision: anonymous public GET, no API keys.**

Rationale:

- Matches `sitemap` and `share-og` — both already serve public data with `verify_jwt = false`.
- API keys add operational overhead (key store, rotation, revocation) with no immediate need.
- RLS on the anon role is the real gate: published-only rows, no PII.
- Rate limiting is per-IP at the edge (see below) — sufficient for v1 partners.

Follow-up (not v1): per-partner API keys with quotas once the first partner onboards and quota
data informs the limits.

---

## Pagination

Reuses `search_events`'s existing cursor (`p_after_start_datetime` + `p_after_id`).

The pair is base64-encoded into an opaque `next_cursor` token so the URL stays clean and the
internals can change without breaking the partner contract. Format:

```
cursor = base64( JSON.stringify({ after_start: <ISO>, after_id: <UUID> }) )
```

The function validates the decoded cursor before passing to the RPC; malformed cursors → 400.

---

## Rate limiting

**v1 decision: no rate limiting implemented (edge-only is not available without additional infra).**

Supabase Edge Functions do not expose a built-in rate-limit primitive. Options:

1. **Upstash Redis + sliding window** — most robust; requires an Upstash account and secret.
2. **Postgres token bucket** (sketched in plan 011) — uses the DB connection pool; adds latency.
3. **Cloudflare Workers / WAF rule** — infrastructure layer; not in this repo.

**Decision (plan 029):** the chosen approach is **option 2 — a Postgres token-bucket RPC** (no new
infra or secrets, fail-open, reusing the advisory-lock pattern from plan 011). The full option
comparison, client-IP source, and a build-ready design (data model, `429` + `Retry-After` /
`X-RateLimit-*` headers, fail-open policy, test plan) live in
[`RATE_LIMITING.md`](./RATE_LIMITING.md). Implementation is a follow-up build plan.

**For now**: do not announce the API publicly until the limiter is implemented. The
`TODO: no rate limit` comment stays in the function until then.

v1 limits once implemented: 100 req / min per IP, burst 200, for GET /events.

---

## Versioning and stability

- Path prefix: Supabase edge functions are served at `/functions/v1/<function-name>`. The function
  name `events-api` is the v1 identifier. A breaking v2 would be a new function `events-api-v2`.
- **Deprecation policy**: 6-month notice before removing or incompatibly changing any field in the
  public event object listed above. New optional fields may be added without notice.
- The `next_cursor` opaque token format may change between versions; clients must treat it as
  opaque and not parse internals.

---

## CORS

**v1 decision: open GET for all origins (`Access-Control-Allow-Origin: *`).**

Rationale: A public read API is meant for partner integrations and aggregators that run on
arbitrary origins. Restricting to the app's own allowlist (`_shared/cors.ts`) would block all
partners. Open GET is standard practice for public read APIs (GitHub API, OpenStreetMap, etc.).

The existing `_shared/cors.ts` allowlist applies to app-facing functions (weather, scrape-source)
where the caller is always the Family Events frontend. The public API is a different trust model.

Scope: `Access-Control-Allow-Origin: *` applies to GET and OPTIONS only. There are no write
endpoints in v1, so CSRF via CORS is not a concern.

---

## Surface safety

**RPC grants (all anon-accessible, published-only):**

| RPC                                | Exposure                                          | Grant                                                            |
| ---------------------------------- | ------------------------------------------------- | ---------------------------------------------------------------- |
| `public.search_events`             | `SETOF events` filtered to `status = 'published'` | anon, authenticated, service_role (see migration 20260601028000) |
| `public.events_enriched_v2`        | RETURNS TABLE (explicit columns)                  | anon, authenticated, service_role (see migration 20260601006000) |
| `public.find_similar_events_by_id` | Similar published events (SECURITY DEFINER)        | anon, authenticated, service_role (see migration 20260618000000) |

**Input validation per parameter (GET /events):**

| Param                  | Validation                                                                          |
| ---------------------- | ----------------------------------------------------------------------------------- |
| `city_id`              | UUID regex; reject non-UUIDs with 400                                               |
| `date_from`, `date_to` | `new Date(v).getTime()` must be finite; reject with 400                             |
| `is_free`              | Must be `"true"` or `"false"`; reject other values with 400                         |
| `tags`                 | Split on comma; each slug matches `/^[a-z0-9-]{1,50}$/`; max 10 tags                |
| `keyword`              | Strip; max 100 chars (matches RPC internal cap); reject longer with 400             |
| `limit`                | Integer 1–100; reject out-of-range with 400                                         |
| `cursor`               | base64-decode + JSON.parse; must produce `{after_start, after_id}` with valid types |

**No write surface**: all endpoints are GET-only. POST/PUT/DELETE → 405.

---

## Open questions

1. **Dedicated public RPC?** `search_events` returns `SETOF events` (the full raw table row).
   The edge function projects only public columns, but a dedicated `public.search_events_public(...)`
   RPC that returns only the safe columns would be safer and remove the projection responsibility
   from the edge layer. Recommend for v1.1.

2. **API key store?** If partners want per-key quotas / analytics, we need a key store (a simple
   `api_keys` table with hashed key + partner_id + quota). Defer to first partner onboarding.

3. **OpenAPI spec generation?** A `GET /events-api/openapi.json` route could serve a machine-readable
   spec. Useful for partners; low effort once the schema is stable.

4. **Write API for community submissions?** Plan 033 (community event submission) adds a public
   write path. Keep it separate (different auth model, rate limits, abuse risk). Do not add it to
   this function.

5. **Cursor token expiry?** Currently opaque base64; no expiry. Long-lived cursors may skip/repeat
   events if the underlying data changes. Document the trade-off; add an `expires_at` field to the
   cursor payload if partners report stale-cursor issues.

6. **`GET /events/:id` fallback to `public_events` view? (RESOLVED)** Plan 028 built the single-event
   endpoint on `events_enriched_v2(p_event_ids => ARRAY[id])` so it returns the identical projection
   (incl. `tags`, `avg_rating`) as the list endpoint with no separate code path. The `public_events`
   view (used by `share-og`) is lighter but lacks the enriched columns; revisit only if single-event
   latency becomes a measured problem.
