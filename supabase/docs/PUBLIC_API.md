# Public Read API — Design Document (v1 spike)

> Status: **Design spike** (plan 018). One PoC endpoint built; remaining endpoints are specified
> but not yet implemented. Open questions are recorded at the bottom.

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

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `city_id` | UUID | — | Filter by city |
| `date_from` | ISO 8601 datetime | — | Inclusive lower bound on `start_datetime` |
| `date_to` | ISO 8601 datetime | — | Inclusive upper bound on `start_datetime` |
| `is_free` | `true`/`false` | — | Free events only |
| `tags` | comma-separated slugs | — | All specified tags must match |
| `keyword` | string ≤ 100 chars | — | Full-text search |
| `limit` | 1–100 | 20 | Page size (capped at 100 for public API; RPC allows 500) |
| `cursor` | opaque string | — | Pagination cursor returned as `next_cursor` in a previous response |

**Response envelope:**

```json
{
  "data": [ /* array of event objects */ ],
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
  "tags": [ { "id": "uuid", "name": "string", "slug": "string", "color": "string" } ],
  "source_url": "string | null",
  "avg_rating": "number",
  "rating_count": "integer"
}
```

**Columns intentionally excluded from v1 (internal / LLM / admin fields):**

| Column | Reason |
|--------|--------|
| `search_vector` | Internal tsvector, not useful to partners |
| `ai_confidence` | Internal LLM metadata |
| `ai_tag_provider` | Internal LLM metadata |
| `parent_tips` | User-facing only, not a partner contract yet |
| `parent_tips_generated_at` | Internal bookkeeping |
| `view_count` | Competitive intelligence risk |
| `source_id` | Internal FK; `source_url` + `source_name` are enough |
| `source_name` | Included: helps partners cite origin |
| `recurrence_info` | Unstable jsonb shape; recurrence is a follow-up |
| `is_favorited` | User-specific, always false for anon |
| `is_in_calendar` | User-specific, always false for anon |
| `created_at` / `updated_at` | Internal bookkeeping |

> **STOP condition note**: `search_events` returns `SETOF events` (the raw table), which includes
> internal columns (`ai_confidence`, `ai_tag_provider`, `search_vector`, etc.). The edge function
> **must** project only the public columns listed above — it must NOT proxy the full row. A dedicated
> public-only RPC would be cleaner long-term (open question below).

---

### `GET /functions/v1/events-api/{id}` — Single event (NOT YET BUILT)

Maps to `events_enriched_v2` filtered by `p_event_ids = ARRAY[id]`.

Same public projection as the list endpoint plus `image_attributions`.
Returns 404 JSON when event is not found or not published.

---

### `GET /functions/v1/events-api/{id}/similar` — Similar events (NOT YET BUILT)

Maps to `find_similar_events_by_id`. Requires plan 017 to be fully landed.
Same public projection as list endpoint.

---

### `GET /functions/v1/events-api/cities` — City list (NOT YET BUILT)

Simple `SELECT id, name, state, country FROM public.cities WHERE is_active = true`.
Response: `{ "data": [ { "id": "uuid", "name": "string", "state": "string", "country": "string" } ] }`.

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

**For now**: do not announce the API publicly until at least option 1 or 3 is in place. Add a
`TODO: no rate limit` comment in the function.

Suggested v1 limits once implemented: 100 req / min per IP, burst 200, for GET /events.

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

| RPC | Exposure | Grant |
|-----|----------|-------|
| `public.search_events` | `SETOF events` filtered to `status = 'published'` | anon, authenticated, service_role (see migration 20260601028000) |
| `public.events_enriched_v2` | RETURNS TABLE (explicit columns) | anon, authenticated, service_role (see migration 20260601006000) |
| `public.find_similar_events_by_id` | Similar published events | anon, authenticated (see migration 20260601029000) |

**Input validation per parameter (GET /events):**

| Param | Validation |
|-------|------------|
| `city_id` | UUID regex; reject non-UUIDs with 400 |
| `date_from`, `date_to` | `new Date(v).getTime()` must be finite; reject with 400 |
| `is_free` | Must be `"true"` or `"false"`; reject other values with 400 |
| `tags` | Split on comma; each slug matches `/^[a-z0-9-]{1,50}$/`; max 10 tags |
| `keyword` | Strip; max 100 chars (matches RPC internal cap); reject longer with 400 |
| `limit` | Integer 1–100; reject out-of-range with 400 |
| `cursor` | base64-decode + JSON.parse; must produce `{after_start, after_id}` with valid types |

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

6. **`GET /events/:id` fallback to `public_events` view?** `events_enriched_v2` is richer but
   heavier. For a single-event lookup, the `public_events` view (used by `share-og`) is faster.
   Decide at implementation time.
