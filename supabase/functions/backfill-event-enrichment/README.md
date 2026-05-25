# backfill-event-enrichment

Fills missing geocodes and images for events the scraper hot-path skipped.
Invoked every 15 min by the `cron-enrich-events` Railway service.

## Environment

| Var | Required | Purpose |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | yes | RPC access for `list_events_needing_enrichment`, `backfill_image_enrichment_in_scope`, `update_event_enrichment`, Unsplash attribution, and download-tracking RPCs. |
| `SUPABASE_URL` | yes | Edge-fn → DB. |
| `UNSPLASH_ACCESS_KEY` | optional | Enables the tag-keyed Unsplash image fallback. Get one at <https://unsplash.com/oauth/applications>. Demo tier (5000 req/hr) is sufficient at our cadence. **Blank → fallback skipped; clients render picsum placeholders.** |

## What it does per tick

Two-pass row claim (so old-row coord backfill never starves featured-event image work):

1. **Legacy pass** — `list_events_needing_enrichment` returns up to N/2 rows ordered by `created_at DESC` that need coords OR images.
2. **Scoped pass** — `backfill_image_enrichment_in_scope` returns up to N/2 rows in the user-visible window (featured OR `start_datetime ∈ [now, now + 30d]`) that need images.

Per row:

- **Coords** — Nominatim geocode. Rows that miss are attempt-marked so they rotate to the back of the queue.
- **Images** — first the scraper re-fetch path (currently returns `[]` because parse-time images are dropped on insert; left in place for future preservation), then Unsplash search keyed by the event's top-confidence tag.
- **Unsplash attribution** — when an Unsplash fallback is written, the same RPC persists per-photo attribution metadata and a durable pending download-tracking row.
- **Unsplash tracking retry** — after a successful DB write, the function awaits the `links.download_location` ping and marks the row succeeded/failed. Each tick also claims pending/failed tracking rows and retries them with DB-backed status.

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
confidence order until one returns a hit with complete photo/photographer
metadata. The search helper does **not** fire-and-forget tracking; tracking
happens only after the DB write succeeds and is retried via
`event_image_attributions` if the HTTP call fails.

## Required attribution

Per Unsplash API guidelines, clients render persisted per-photo attribution as
"Photo by <photographer> on Unsplash" next to images sourced from Unsplash. The
public `events_enriched_v2.image_attributions` JSON excludes tracking internals
(`download_location`, status, attempts, errors).

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
images_from_scraper / images_from_unsplash / errors` plus
`unsplash_tracking.pending_claimed / tracked / failed`.
