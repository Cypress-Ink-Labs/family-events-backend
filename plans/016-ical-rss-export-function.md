# Plan 016 (spike): iCal + RSS export edge function

> **Executor instructions**: This is a SPIKE/DESIGN plan — its deliverable is a working prototype +
> documented decisions, not a fully productized feature. Follow the steps, but where a step says
> "decide" or "investigate", record your finding in the plan's "Open questions" outcome rather than
> guessing. Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/sitemap supabase/functions/share-og supabase/migrations`

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (new public read-only endpoint; no mutation, no new auth surface if events are already public)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `6c0db23`, 2026-06-17
- **Implemented at**: 2026-06-18

## Open questions / spike findings

### Feed scope decision

Chose: global published upcoming events (start_datetime >= now), with optional `?city=<uuid>` filter. User-scoped (saved events) feeds require auth — explicitly out of spike scope and noted here for follow-up.

### Which RPC was reused

`events_enriched_v2` — best fit. It: returns all needed fields (id, title, description, start_datetime, end_datetime, timezone, venue_name, address, recurrence_info, source_url), supports `p_city_id` for per-city filtering, is granted to `anon`, and respects `p_date_from` for upcoming-only filtering. Max limit is 200 (matches FEED_LIMIT). No new query was added.

### Recurrence mapping feasibility

`recurrence_info` is jsonb. Observed shape in migrations: `{ "rrule": "FREQ=WEEKLY;COUNT=4" }` (from spike fixture). The field is populated by the scraper/ingest pipeline. Direct RRULE pass-through would work for simple cases (FREQ=WEEKLY/DAILY/MONTHLY + COUNT/UNTIL). Blockers for full support:

1. Not all scrapers populate `recurrence_info` consistently — shape validation would be needed.
2. RFC 5545 RRULE requires the RRULE value line, but also individual occurrences may need `EXDATE` for cancelled instances — that data doesn't exist yet.
3. For the spike: single-occurrence emission is safe and correct; calendar clients show one instance. Follow-up: add `RRULE:` mapping when `recurrence_info.rrule` is present (straightforward pass-through).

### iCal escaping vs XML escaping

Confirmed: separate implementations. iCal text escaping (`\,` `\;` `\\` `\n`) is distinct from XML/HTML escaping (`&amp;` `&lt;` etc). The test suite covers this with a cross-format assertion.

## Why this matters (product)

Users currently must open the web app to see events. The data model already carries everything a calendar
feed needs (`events.start_datetime`, `end_datetime`, `timezone`, `title`, `description`, venue/address,
`recurrence_info`), and the scraper already **parses** inbound `.ics` — producing one is the mirror image
of work already done. An iCal feed lets users subscribe in Apple/Google/Outlook Calendar; an RSS feed
feeds readers and aggregators. Both are public, cacheable, low-maintenance, and increase passive
engagement. Grounding: `sitemap` and `share-og` already prove the public-HTTP-over-RPC pattern in this repo.

## Current state (what to model on)

- `supabase/functions/sitemap/index.ts` is the closest existing pattern: a public GET edge function that
  queries published events, serializes them to XML with `escapeXml`, and sets edge cache headers
  (`CACHE_CONTROL = "public, max-age=3600, s-maxage=3600, stale-while-revalidate=600"`). It defines
  `STATIC_PAGES`, `escapeXml`, `toW3CDate`, and a `robotsTxt` handler.
- `supabase/functions/share-og/index.ts` shows public event lookup with a short cache TTL, a `PublicEventRow`
  shape (`id, title, description, venue_name, start_datetime, images`), UUID validation, and careful
  string-escaping for embedding untrusted content (`serializeForInlineScript`, U+2028/2029 handling).
- `config.toml` sets `verify_jwt = false` for public functions like `sitemap`/`share-og`; a new public
  feed function needs the same + an entry in `config/deploy.config.json` `functions` +
  `noVerifyJwtFunctions` (the deploy-cli guard test requires the function dir, which must contain
  `index.ts`, to be listed — see `tests/guards/deploy-cli-boundary.test.mjs`).
- There is already an RPC surface for published events (`events_enriched` / `events_enriched_v2`,
  `search_events`) — investigate which returns the fields the feed needs in one call.

## Steps

### Step 1: Decide the feed scope (investigate, then record)

- Which events does a feed contain? Options: all published events in a city (`?city=<uuid>`), all
  published events globally, or a user's saved events (would require auth — out of spike scope, note it).
  Recommend: **per-city published upcoming events** (`?city=<slug-or-uuid>`), matching `search_events`/
  `events_enriched` filtering. Record the decision.
- Which existing RPC returns the needed columns? Prefer reusing one (`events_enriched_v2`?) over a new query.

### Step 2: Build the function skeleton

Create `supabase/functions/events-feed/index.ts` modeled on `sitemap/index.ts`:

- Public GET, `verify_jwt = false`, edge cache headers (use sitemap's `CACHE_CONTROL`; events mutate, so a
  ~1h TTL with stale-while-revalidate is appropriate).
- Route on a `format` query param or path suffix: `?format=ics` → `text/calendar`, `?format=rss` →
  `application/rss+xml`. Default could be RSS.
- Query published events via the chosen RPC (service-role or anon client per how sitemap does it).

### Step 3: iCal serialization (RFC 5545)

- Emit a `VCALENDAR` with one `VEVENT` per event: `UID` (use event id + a stable domain),
  `DTSTART`/`DTEND` (use `events.timezone`; emit as UTC `Z` times or with `TZID` — UTC is simpler and
  correct), `SUMMARY`, `DESCRIPTION`, `LOCATION`, `URL` (the app event page).
- Escape per RFC 5545 (commas, semicolons, newlines, backslashes in text values) — do NOT reuse `escapeXml`.
- **Recurrence is the hard part**: `recurrence_info` is `jsonb`. For the spike, emit only single occurrences
  (skip/expand-not) and **record** what `recurrence_info` actually contains and whether an `RRULE` mapping
  is feasible as a follow-up. Do not block the spike on full recurrence support.

### Step 4: RSS serialization

- Emit an RSS 2.0 `channel` with one `item` per event: `title`, `link` (app event page), `description`,
  `pubDate` (event start, W3C/RFC-822), `guid` (event id). Reuse the XML-escaping approach from `sitemap`.

### Step 5: Register + smoke test

- Add `events-feed` to `config/deploy.config.json` `functions` and `noVerifyJwtFunctions`, and a
  `[functions.events-feed]` block with `verify_jwt = false` in `supabase/config.toml`.
- Add a unit test for the serializers (feed-shape from fixture rows → valid iCal/RSS strings; assert
  escaping of a title containing `,`/`<`/newline). Model the test on an existing function test.

## Commands you will need

| Purpose        | Command                                                                               | Expected                                                   |
| -------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Typecheck      | `pnpm run check`                                                                      | exit 0                                                     |
| Guard tests    | `pnpm run workspace:test`                                                             | deploy-cli + auth-config guards pass (function registered) |
| Function tests | `deno test` (cwd `supabase/functions`) / `pnpm -C supabase/functions exec vitest run` | serializer tests pass                                      |
| Serve locally  | `pnpm run db:functions:serve` then curl `?format=ics` / `?format=rss`                 | valid feed output                                          |
| Validate iCal  | paste output into an RFC 5545 validator or import into a calendar app                 | parses                                                     |

## Deliverable / Done criteria

- [x] `events-feed` function returns valid `text/calendar` and `application/rss+xml` for published events
- [x] Serializers are unit-tested incl. escaping
- [x] Function registered in `config.toml` + `deploy.config.json`; guard tests pass
- [x] `pnpm run check` exits 0
- [x] "Open questions" recorded: recurrence mapping feasibility, feed scope decision, which RPC was reused
- [x] `plans/README.md` row for 016 updated

## STOP conditions

- No existing RPC exposes the needed published-event fields and adding one balloons the spike — record
  that and propose the RPC as a follow-up rather than building a large query inline.
- `recurrence_info` is richer than a simple RRULE can express — emit single occurrences, document, move on.

## Maintenance notes

- This is a spike: the goal is a working, tested feed for the common case + a written record of the
  recurrence/scope decisions. Productization (per-user feeds, full RRULE, signed private feeds) is
  explicit follow-up.
- Reviewer: confirm escaping is format-correct (iCal ≠ XML escaping) and the cache TTL won't pin
  cancelled events for too long (mirror `share-og`'s reasoning).
