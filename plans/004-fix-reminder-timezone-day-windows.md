# Plan 004: Reminder day-windows are computed in the event timezone, not UTC

> **Executor instructions**: Follow step by step; run every verification command. Honor STOP
> conditions — especially the one about `send-weekly-digest`. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/send-reminders`
> If `send-reminders/index.ts` changed, compare the excerpts below against the live file before editing.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (changes which events match the reminder windows; a wrong tz helper sends reminders on
  the wrong day — the new unit tests are the safety net)
- **Depends on**: 001 (so the new vitest tests run in CI)
- **Category**: bug
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

`send-reminders` decides "day-before" and "morning-of" reminders by computing **calendar-day boundaries
in UTC** and comparing them to `events.start_datetime` (stored UTC). The app is single-region
(Lafayette / Baton Rouge, LA) and `events.timezone` defaults to **`America/Chicago`** (UTC−5/−6). A
Chicago calendar day starts 5–6 hours after the UTC day. So an event at, say, 7:00 PM Chicago time on
day D is stored as `D+1T00:00Z` (next UTC day). The UTC window misfiles it: it can land in the wrong
day's query or be skipped entirely, so favorited-event reminders fire on the wrong day or not at all for
a large fraction of events. This is a correctness bug that directly degrades the product's core
notification value.

## Current state

`supabase/functions/send-reminders/index.ts:63-105` (the buggy window computation + queries):

```ts
// Compute date boundaries in UTC
const now = new Date();
const todayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
const todayEnd = new Date(todayStart.getTime() + 24 * 60 * 60 * 1000);
const tomorrowStart = new Date(todayEnd);
const tomorrowEnd = new Date(tomorrowStart.getTime() + 24 * 60 * 60 * 1000);
// ...
const { data: dayBeforeRows, error: dbErr } = await supabase
  .from("favorites")
  .select(
    `user_id, event_id, events!inner(id, title, start_datetime, venue_name, address, status), user_profiles!inner(email, display_name)`,
  )
  .gte("events.start_datetime", tomorrowStart.toISOString())
  .lt("events.start_datetime", tomorrowEnd.toISOString())
  .eq("events.status", "published");
// ... morningOfRows uses todayStart / todayEnd identically.
```

Relevant facts:

- `events.timezone` column exists, `DEFAULT 'America/Chicago' NOT NULL`
  (`supabase/migrations/20260601000000_schema_baseline.sql:1547`).
- The function runs under `serveServiceRoleJson` (`send-reminders/index.ts:58`); the handler returns a
  summary object.
- `send-reminders/send-reminders.test.ts` already exists (vitest) and tests utilities like
  `deduplicateTargets`, `flattenRows`, `formatEventDate`. New tests go here, same style.

**IMPORTANT — `send-weekly-digest` is NOT in scope.** It uses a _rolling_ window
(`send-weekly-digest/index.ts:388-396`: `now .. now + 7 days` passed to an RPC), which has no
calendar-day boundary and therefore no timezone bug. Do not touch it. (This corrects an over-broad audit note.)

## Commands you will need

| Purpose         | Command                                                                      | Expected                 |
| --------------- | ---------------------------------------------------------------------------- | ------------------------ |
| Install         | `pnpm install --frozen-lockfile`                                             | exit 0                   |
| Typecheck       | `pnpm run check`                                                             | exit 0                   |
| Run these tests | `pnpm -C supabase/functions exec vitest run send-reminders`                  | all pass incl. new cases |
| Deno tests      | `deno test` in `supabase/functions/send-reminders` (if a `*_test.ts` exists) | pass                     |

## Scope

**In scope:**

- `supabase/functions/send-reminders/index.ts`
- `supabase/functions/send-reminders/send-reminders.test.ts` (add cases)
- Optionally a new helper file `supabase/functions/_shared/zoned-time.ts` + its `*.test.ts` if you
  decide the helper belongs in `_shared` (it is reusable). Either location is acceptable; keep the
  helper unit-tested.

**Out of scope:**

- `supabase/functions/send-weekly-digest/**` — different (correct) windowing; do not change.
- The `favorites`/`events` query shape and the dedup/preferences logic — leave as-is except for the
  boundary values fed into `.gte`/`.lt`.
- Adding per-user timezones — this app is single-region; see Maintenance notes.

## Steps

### Step 1: Add a timezone-aware day-boundary helper

Write a pure function that, given an instant and an IANA timezone, returns the UTC instants for the
start of "today" and "tomorrow" **in that zone**:

```ts
// Returns the UTC Date for midnight (00:00) of the given zone-local day offset.
// dayOffset 0 = start of today (zone-local), 1 = start of tomorrow, etc.
export function zonedDayStartUtc(now: Date, timeZone: string, dayOffset: number): Date;
```

Implementation approach (no external deps — Deno + vitest both have `Intl`):

1. Use `Intl.DateTimeFormat("en-US", { timeZone, year, month, day, hour, minute, second, hour12: false })`
   `.formatToParts(now)` to read the zone-local wall-clock Y/M/D.
2. Compute the zone's current UTC offset: build a `Date` from those wall-clock parts as if they were UTC
   (`Date.UTC(...)`), subtract `now`'s epoch; that difference is the offset.
3. Zone-local midnight of (today + dayOffset) as a UTC instant = `Date.UTC(y, m, d + dayOffset) - offset`.

This must be correct across a DST transition — write tests for it (Step 3).

### Step 2: Use the helper for the window boundaries

Replace the UTC boundary block (lines 63-68) so the four boundaries come from the helper with
`timeZone = "America/Chicago"` (introduce a module constant `const REMINDER_TZ = "America/Chicago"`):

```ts
const now = new Date();
const todayStart = zonedDayStartUtc(now, REMINDER_TZ, 0);
const todayEnd = zonedDayStartUtc(now, REMINDER_TZ, 1);
const tomorrowStart = todayEnd;
const tomorrowEnd = zonedDayStartUtc(now, REMINDER_TZ, 2);
```

Leave the `.gte(...).lt(...)` query lines unchanged — they already call `.toISOString()` on these Dates.

**Verify**: `pnpm run check` exits 0.

### Step 3: Tests

In `send-reminders.test.ts` (or the helper's own `*.test.ts`), add cases for `zonedDayStartUtc`:

- **Standard time (CST, UTC−6)**: `now = 2026-01-15T12:00:00Z`. `zonedDayStartUtc(now, "America/Chicago", 0)`
  must equal `2026-01-15T06:00:00Z` (Chicago midnight Jan 15 = 06:00Z).
- **Daylight time (CDT, UTC−5)**: `now = 2026-07-15T12:00:00Z` → start of today = `2026-07-15T05:00:00Z`.
- **Cross-UTC-midnight case**: `now = 2026-01-15T03:00:00Z` (which is still Jan 14 in Chicago, 21:00 CST).
  Start of "today" must be `2026-01-14T06:00:00Z`, NOT Jan 15 — this is the exact case the old UTC code got wrong.
- **dayOffset 1 and 2** produce consecutive zone-local midnights (24h apart in standard time).

Model the test file structure on the existing `describe`/`it` blocks in `send-reminders.test.ts`.

**Verify**: `pnpm -C supabase/functions exec vitest run send-reminders` → all pass, including the new cases.

## Done criteria

ALL must hold:

- [ ] `pnpm run check` exits 0
- [ ] `grep -n "Date.UTC(now.getUTCFullYear" supabase/functions/send-reminders/index.ts` returns nothing
      (old UTC boundary removed)
- [ ] `zonedDayStartUtc` (or equivalently named helper) exists and is unit-tested with the DST +
      cross-midnight cases above
- [ ] `pnpm -C supabase/functions exec vitest run send-reminders` passes
- [ ] `send-weekly-digest/**` is unchanged (`git status`)
- [ ] Only in-scope files modified
- [ ] `plans/README.md` row for 004 updated

## STOP conditions

Stop and report (do not improvise) if:

- The "Current state" excerpt doesn't match `send-reminders/index.ts` (drift).
- You discover the deployment actually runs `send-reminders` on a schedule that already accounts for tz
  (e.g. a cron that fires at Chicago midnight) such that the UTC math was intentional — in that case the
  fix interacts with the cron schedule; report before changing.
- The reminder cron is invoked more than once per day in a way that makes "today/tomorrow" windows
  overlap — report; the dedup key may need the date too.

## Maintenance notes

- This hardcodes `America/Chicago` because the app is single-region and `events.timezone` defaults to it.
  **If multi-region is ever added**, the window must be computed per event's `timezone` column (or per
  user's timezone) — at that point the single global window approach breaks and the query/grouping must
  change. Leave a `// NOTE:` to that effect at `REMINDER_TZ`.
- Reviewer: scrutinize the offset math in `zonedDayStartUtc` against the DST test vectors — that is the
  only load-bearing logic here.
