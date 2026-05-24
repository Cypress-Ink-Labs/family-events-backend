# backfill-event-enrichment

Fills missing geocodes and images for events the scraper hot-path skipped.
Invoked every 15 min by the `cron-enrich-events` Railway service.

## Environment

| Var | Required | Purpose |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | yes | RPC access for `list_events_needing_enrichment`, `backfill_image_enrichment_in_scope`, `update_event_enrichment`. |
| `SUPABASE_URL` | yes | Edge-fn → DB. |
| `UNSPLASH_ACCESS_KEY` | optional | Enables the tag-keyed Unsplash image fallback. Get one at <https://unsplash.com/oauth/applications>. Demo tier (5000 req/hr) is sufficient at our cadence. **Blank → fallback skipped; clients render picsum placeholders.** |

## What it does per tick

Two-pass row claim (so old-row coord backfill never starves featured-event image work):

1. **Legacy pass** — `list_events_needing_enrichment` returns up to N/2 rows ordered by `created_at DESC` that need coords OR images.
2. **Scoped pass** — `backfill_image_enrichment_in_scope` returns up to N/2 rows in the user-visible window (featured OR `start_datetime ∈ [now, now + 30d]`) that need images.

Per row:

- **Coords** — Nominatim geocode → city centroid fallback.
- **Images** — first the scraper re-fetch path (currently returns `[]` because parse-time images are dropped on insert; left in place for future preservation), then Unsplash search keyed by the event's top-confidence tag.

Skips the DB update entirely when nothing changed so `updated_at` doesn't tick.

## Tag-keyed Unsplash search

Search URL:

```
https://api.unsplash.com/search/photos
  ?query=<tag>+family
  &orientation=landscape
  &per_page=1
  &content_filter=high
```

`content_filter=high` enables Unsplash safe-search. Walks `row.tags` in
confidence order until one returns a hit. Triggers the required
`links.download_location` ping per Unsplash API guidelines. Failure on
any one tag falls through to the next; failure on all leaves the row's
`images = []` and the next 15-minute tick will retry.

## Required attribution

Per Unsplash API guidelines, the app must surface a credit line. Already
present on web at `/profile` (`apps/web/src/features/profile/pages/profile.tsx`).
iOS + Android attribution follows in a separate small commit.

## Local development

Set `UNSPLASH_ACCESS_KEY` in `supabase/functions/.env`, then:

```bash
pnpm run db:start
supabase functions serve backfill-event-enrichment
# trigger one tick:
curl -X POST \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  http://127.0.0.1:54321/functions/v1/backfill-event-enrichment
```

Response body summarises `claimed / updated / coords / images /
images_from_scraper / images_from_unsplash / errors`.
