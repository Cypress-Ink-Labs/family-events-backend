# Plan 009: backfill-event-enrichment caches geocode + stock-image lookups within a batch

> **Executor instructions**: Follow step by step. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/backfill-event-enrichment`

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (adds in-memory memoization; same external results, fewer calls)
- **Depends on**: 001
- **Category**: perf
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

The enrichment batch loop calls geocoding (Nominatim, rate-limited to 1 req/sec) and stock-image search
(Pexels/Pixabay/Unsplash — hourly caps: Unsplash 50/hr, Pexels 200/hr) **once per event**, with no reuse
across events in the same batch. Many events in one regional batch share a venue/address (same library,
same park) or the same tag set, so the same geocode query and the same image search are repeated. The
loop already threads a `cityCache` and `sourceCache` — but not a geocode cache or an image cache. Adding
those cuts redundant external calls, which both speeds the batch (it runs under a ~110s budget) and
conserves scarce provider quota.

## Current state

`supabase/functions/backfill-event-enrichment/index.ts`:

- The batch loop (lines 573-608) already builds and threads two caches into `enrichOne`:
  ```ts
  const cityCache = new Map<string, SourceCityContext | null>();
  const sourceCache = new Map<string, string | null>();
  for (const row of rows) {
    const result = await enrichOne(supabase, row, cityCache, sourceCache, providerKeys);
    // ...summary bookkeeping...
  }
  ```
- Stock-image fallback per row (lines 251-257):
  ```ts
  if (row.needs_images && images.length === 0 && row.tags.length > 0) {
    stockResult = await findFallbackImage(row.tags, providerKeys, { title: row.title });
    if (stockResult) { images = [stockResult.url]; imageSource = stockResult.attribution.provider; }
  }
  ```
- Geocoding happens inside `enrichOne` as well (search the function for `geocodeViaNominatim` /
  `buildGeocodeQuery` — both are exported from `supabase/functions/_shared/geocode.ts`). The geocode query
  string is built from address/venue/city (`buildGeocodeQuery`), which is the natural cache key.

## Steps

### Step 1: Add a geocode cache keyed on the query string

In the batch loop (next to `cityCache`/`sourceCache`), add:
```ts
const geocodeCache = new Map<string, GeocodeResult | null>();
```
Thread it into `enrichOne` (add a parameter). Inside `enrichOne`, where it currently calls
`geocodeViaNominatim(query)`, first build the query string (it already does, via `buildGeocodeQuery`),
then:
```ts
if (geocodeCache.has(query)) {
  result = geocodeCache.get(query)!;
} else {
  result = await geocodeViaNominatim(query);
  geocodeCache.set(query, result);
}
```
Cache **both** hits and misses (`null`) — a venue that doesn't geocode shouldn't be retried per event in
the same batch. Use the exact `query` string (already normalized by `buildGeocodeQuery`) as the key.

### Step 2: Add a stock-image cache keyed on the tag set

In the batch loop add:
```ts
const imageCache = new Map<string, Awaited<ReturnType<typeof findFallbackImage>>>();
```
Thread it into `enrichOne`. Before calling `findFallbackImage(row.tags, providerKeys, { title: row.title })`,
compute a stable key. The image search is driven by `row.tags` (and falls back to title-derived terms), so
key on the sorted tag slugs: `const imageKey = [...row.tags].sort().join(",");`. Then:
```ts
let stockResult = imageCache.get(imageKey);
if (stockResult === undefined) {
  stockResult = await findFallbackImage(row.tags, providerKeys, { title: row.title });
  imageCache.set(imageKey, stockResult);
}
```
Note: `findFallbackImage`'s third arg includes `{ title }`, which varies per event — but the **tag-keyed**
fallback is the dominant path and the cache is a best-effort dedup within one batch. If two events share
the exact tag set, reusing the image is acceptable (they're thematically identical). Document this in a
comment. If you judge title to matter, include a coarse title bucket in the key — but prefer the simpler
tag-only key and note the tradeoff.

### Step 3: Verify behavior is preserved

The summary counters (`summary.images_from_pexels`, etc.) are derived from `result.imageSource` /
`result.gotCoords` per row — a cache hit must still return the same `imageSource`/coords for that row so
the counters stay accurate. Confirm `enrichOne` returns the cached provider/source, not a generic
"cached" marker.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Typecheck | `pnpm run check` | exit 0 |
| Tests | `pnpm -C supabase/functions exec vitest run backfill-event-enrichment` and/or `deno test` | pass |

## Scope

**In scope:** `supabase/functions/backfill-event-enrichment/index.ts` and its test(s)
(`backfill-event-enrichment/*_test.ts` / `parent-tips-pass_test.ts` are siblings — add a cache test).
**Out of scope:** `_shared/geocode.ts` and `_shared/stock-images.ts` internals (don't change the providers
or the geocoder — only memoize the calls). The Nominatim cross-instance rate limiter is plan 011.

## Steps — Test

Add a test that runs `enrichOne`/the batch over two rows with the **same** address and same tags, with a
fake geocoder + fake image finder that count calls, and assert each external function is called **once**,
not twice, while both rows still receive the correct coords/image/`imageSource`.

## Done criteria

- [ ] `geocodeCache` and `imageCache` exist in the batch loop and are threaded into `enrichOne`
- [ ] Both hits and misses are cached (geocode), and duplicate tag-sets reuse the image result
- [ ] Summary counters remain correct on cache hits (test asserts `imageSource`/coords on the 2nd row)
- [ ] A test proves duplicate inputs cause a single external call each
- [ ] `pnpm run check` exits 0; tests pass
- [ ] `plans/README.md` row for 009 updated

## STOP conditions

- `enrichOne` is structured so geocoding happens before the query string is known, making the cache key
  ambiguous — report the actual structure; do not key on something unstable.
- `findFallbackImage` has side effects beyond returning a result (e.g. it records a download for
  attribution) such that caching would skip a required side effect — in that case cache only the geocode,
  skip the image cache, and note why. (Check `runPendingUnsplashTrackingPass` / attribution tracking near
  line 610.)

## Maintenance notes

- Caches are per-batch (per function invocation), intentionally — no cross-invocation state.
- Reviewer: confirm misses are cached for geocode (the common starvation case is unfillable venues retried
  every event).
