# Plan 011: Nominatim requests honor the 1 req/sec limit across all function instances

> **Executor instructions**: This is the highest-uncertainty performance plan — read the STOP conditions
> first. Follow step by step. Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/_shared/geocode.ts`

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: MED (a shared limiter adds DB coordination; a bad implementation can serialize/stall geocoding
  or deadlock)
- **Depends on**: 001
- **Category**: perf (correctness/compliance — Nominatim ToS)
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

`geocodeViaNominatim` enforces Nominatim's 1 request/second policy with **module-level** state
(`lastNominatimRequestAt`, `nominatimQueue`). That state is per V8 isolate. When more than one edge
function instance geocodes concurrently (e.g. `backfill-event-enrichment` running alongside `tag-event`,
or multiple warm instances), each independently allows 1 req/sec, so aggregate traffic exceeds the policy.
Nominatim throttles or bans abusive IPs — which would break geocoding entirely. The fix is a coordination
point shared across instances.

## Current state

`supabase/functions/_shared/geocode.ts:19-65`:

```ts
const NOMINATIM_RATE_LIMIT_MS = 1_000
let lastNominatimRequestAt = 0
let nominatimQueue: Promise<void> = Promise.resolve()

async function waitForNominatimSlot(): Promise<void> {
  // chains onto module-level nominatimQueue, sleeps until 1s since lastNominatimRequestAt
}

export async function geocodeViaNominatim(query: string): Promise<GeocodeResult | null> {
  // ...
  await waitForNominatimSlot()
  const res = await fetch(url, { headers: { "User-Agent": NOMINATIM_UA, ... }, signal: AbortSignal.timeout(5_000) })
  // ...
}
```

This in-isolate limiter is correct *within* one instance but does not coordinate across instances.

## Approach — pick ONE, in this preference order

This is genuinely a design choice; the right answer depends on operational facts you must confirm first
(see STOP conditions). Options, best-fit first:

1. **Postgres advisory-lock + timestamp token (recommended).** Add an RPC (new migration + rollback,
   following the `private` body + `public` wrapper, `service_role`-only grant style of
   `supabase/migrations/20260601029000_*`) that atomically reserves the next Nominatim slot:
   - A tiny table `private.geocoder_rate_state(id int primary key default 1, last_request_at timestamptz)`.
   - An RPC `private.reserve_nominatim_slot(min_interval_ms int)` that takes a transaction-scoped advisory
     lock (`pg_advisory_xact_lock(<const>)`), reads `last_request_at`, computes the wait needed, sets
     `last_request_at = greatest(now(), last_request_at + interval)`, and returns the number of ms the
     caller should sleep before fetching. The lock serializes the read-modify-write across instances.
   - `geocodeViaNominatim` calls the RPC (via a service-role client it must now receive), sleeps the
     returned ms, then fetches. Keep the in-isolate limiter as a cheap local pre-throttle too.
   - **Tradeoff:** every geocode now does one DB round-trip. At 1 req/sec that's negligible.

2. **Single-flight geocoding service.** Route all geocoding through one dedicated edge function / queue so
   only one instance ever calls Nominatim. Larger refactor; only if option 1 is infeasible.

3. **Accept + degrade.** If concurrent geocoding instances are confirmed rare, document the limitation,
   add the `city-fallback` path as the throttle response handler (on HTTP 429 from Nominatim, fall back to
   city centroid instead of retrying), and lower the blast radius without full coordination.

## Steps (option 1)

### Step 1: Migration — state table + reserve RPC (+ rollback)
Create the table, the `SECURITY DEFINER` reserve RPC with `search_path TO ''`, grant EXECUTE to
`service_role` only, REVOKE from PUBLIC/anon/authenticated. Add the paired `_down.sql`
(drop function, drop table). New timestamp strictly greater than the current max migration.

### Step 2: Thread a supabase client into `geocodeViaNominatim`
The function currently takes only `query`. Add a parameter for a service-role `SupabaseClient` (or a
`reserveSlot: () => Promise<number>` callback so it stays unit-testable without a DB). Update all callers
(`grep -rn "geocodeViaNominatim" supabase/functions`) to pass it. Inside, replace `await waitForNominatimSlot()`
with: call the reserve RPC → `await sleep(ms)` → fetch.

### Step 3: Handle Nominatim 429 explicitly
On HTTP 429 (or repeated failures), return `null` (caller already falls back) and log a warning — do not
hot-retry.

### Step 4: Tests
Unit-test the wait math with a fake `reserveSlot` returning various ms. If you keep the callback seam,
tests need no DB. Optionally add a DB test under `supabase/tests/` that two concurrent `reserve_nominatim_slot`
calls return non-overlapping slots.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Typecheck | `pnpm run check` | exit 0 |
| Function tests | `pnpm -C supabase/functions exec vitest run` + `deno test` | pass |
| Rollback guard | `pnpm run workspace:test` | new migration is paired |
| Regenerate types | `pnpm run db:types` | new RPC in `database.types.ts`; commit |

## Done criteria

- [ ] Geocoding reserves its slot through a cross-instance coordination point (RPC), not just module state
- [ ] New migration + paired rollback; `pnpm run workspace:test` passes
- [ ] All `geocodeViaNominatim` callers updated
- [ ] Wait math unit-tested via an injectable seam
- [ ] `pnpm run check` exits 0; types regenerated
- [ ] `plans/README.md` row for 011 updated

## STOP conditions

Stop and report **before implementing** if you cannot confirm:
- Whether multiple geocoding instances actually run concurrently in production (check the cron schedules
  in `config/deploy.config.json` / Railway and whether `tag-event` geocodes alongside `backfill-event-enrichment`).
  If concurrency is impossible, option 3 (document + degrade) is the correct, far cheaper answer — do that instead.
- During implementation, if the advisory-lock RPC measurably serializes geocoding to slower than 1/sec or
  risks lock contention with other workloads — stop and reconsider (option 2 or 3).

## Maintenance notes

- Reviewer: the failure mode to guard against is *stalling* geocoding. Confirm the lock is `xact`-scoped
  (auto-released) and the sleep happens *outside* the lock/transaction.
- This is the kind of finding where "document the limitation + degrade on 429" is a legitimate, lower-cost
  resolution. Don't over-engineer if concurrency is rare.
