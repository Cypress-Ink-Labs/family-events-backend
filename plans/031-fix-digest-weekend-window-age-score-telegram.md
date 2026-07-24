# Plan 031: Fix digest weekend window, age scoring, and Telegram gating

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. Honor STOP conditions — do not improvise. When done, update your row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2f10101..HEAD -- supabase/functions/_shared/zoned-time.ts supabase/functions/_shared/zoned-time.test.ts supabase/functions/send-weekly-digest/index.ts supabase/functions/send-weekly-digest/send-weekly-digest_test.ts supabase/migrations supabase/rollbacks supabase/tests/plan_events_for_user_range_age.sql`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none; plan 035 must build on this plan's migrated RPC body
- **Category**: bug
- **Planned at**: commit `2f10101`, 2026-07-24

## Why this matters

The weekly digest builds a Friday-through-Sunday window with UTC calendar operations even though the product is explicitly America/Chicago-local. During CDT this becomes Thursday 19:00 through Sunday 18:59 local, leaking Thursday events and excluding Sunday evening events. Event display times are also formatted in the host timezone. Separately, one-sided age ranges receive false perfect scores because a missing bound is coalesced to the child's age, and a missing Resend key exits before Telegram dispatch, suppressing Telegram-only digests. This plan fixes all three correctness defects before plan 035 restructures the same handler and RPC.

## Current state

- `supabase/functions/send-weekly-digest/index.ts:514-527` uses `getUTCDay` and `setUTCHours(0, 0, 0, 0)` to construct the weekend window.
- `splitDateTime` at `send-weekly-digest/index.ts:128-140` calls `toLocaleDateString` and `toLocaleTimeString` without `timeZone`; Deno's host timezone can therefore shift output by five or six hours.
- `supabase/functions/_shared/zoned-time.ts:34-59` derives `offsetMs` from `now` and applies it to `day + dayOffset`. A target day across a DST boundary can use the wrong offset and be one hour off.
- `supabase/migrations/20260620030000_plan_events_for_user_range.sql:98-99` uses `BETWEEN p_date_from AND p_date_to`, making both endpoints inclusive.
- The age factor at `20260620030000_plan_events_for_user_range.sql:174-186` currently computes:
  ```sql
  LEAST(
    ABS(COALESCE(e.age_min, p_kid_age) - p_kid_age),
    ABS(COALESCE(e.age_max, p_kid_age) - p_kid_age)
  )
  ```
  A missing bound thus contributes distance zero and can force score 1.0.
- `send-weekly-digest/index.ts:629-646` returns from the whole handler when `RESEND_API_KEY` is missing. The Telegram branch at approximately lines 704-727 is never reached.
- `_shared/zoned-time.ts` documents a single-zone product. Use `America/Chicago`; per-event timezone behavior is out of scope.
- Migrations are append-only and require matching rollback files under `supabase/rollbacks/`. Choose the next free `20260724NNNNNN` timestamp by listing existing migrations; never modify the historical migration.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Typecheck | `pnpm run check` | exit 0 |
| Guard tests | `pnpm run workspace:test` | all pass |
| Deno fn tests | `pnpm run test:deno` | all pass |
| vitest | `pnpm run test:functions` | all pass |
| Lint | `pnpm run lint` | exit 0 |
| DB tests (needs local DB) | `pnpm run db:start && pnpm run db:test` | all pass |

> **Local pnpm caveat**: pnpm scripts may fail locally on the documented supply-chain policy. If that occurs, run the corresponding oxlint, Deno, vitest, or Node binaries directly as documented in `plans/README.md`; do not treat the policy failure as a product test failure.

## Scope

**In scope** (the only files you should modify):
- `supabase/functions/_shared/zoned-time.ts`
- `supabase/functions/_shared/zoned-time.test.ts` (new)
- `supabase/functions/send-weekly-digest/index.ts`
- `supabase/functions/send-weekly-digest/send-weekly-digest_test.ts`
- One new `supabase/migrations/20260724NNNNNN_plan_events_range_halfopen_and_age_fix.sql`
- Its paired `supabase/rollbacks/20260724NNNNNN_plan_events_range_halfopen_and_age_fix_down.sql`
- `supabase/tests/plan_events_for_user_range_age.sql` (new)

**Out of scope**:
- Per-user ranking RPC fan-out or recipient pagination; plan 035 owns those changes
- `send-reminders` caller behavior or reminder-window policy
- Per-event timezone formatting or multi-region support
- Telegram request behavior beyond removing the Resend gate
- Any change to score weights or ranking order

## Git workflow

- Branch: `advisor/031-fix-digest-weekend-window-age-score-telegram`
- Commit per logical unit using Conventional Commits, for example `fix(functions): use local weekend digest window`.
- Do NOT push or open a PR unless the operator instructs.

## Steps

### Step 1: Make zoned day starts target-date offset aware

In `supabase/functions/_shared/zoned-time.ts`, change `zonedDayStartUtc` so it resolves the UTC offset at the target day's local midnight, not at `now`.

Use a two-pass conversion:

1. Read the local year/month/day and weekday from `now` using the existing `Intl.DateTimeFormat(...).formatToParts` wall-clock-parts technique.
2. Estimate `Date.UTC(year, month - 1, day + dayOffset)` minus the initial offset.
3. Re-derive the offset at that estimated instant with the same wall-clock-parts calculation.
4. Recompute the target midnight with that target-date offset.

Add `weekday` to the formatter parts and export:

```ts
/** Upcoming-weekend window as UTC instants: [Friday 00:00, Monday 00:00) zone-local. */
export function weekendWindowUtc(
  now: Date,
  timeZone: string,
): { from: Date; to: Date }
```

Weekday semantics must mirror the existing weekend logic in local time: Saturday selects yesterday's Friday; Sunday selects Friday two days earlier; every other day selects the upcoming Friday (`5 - weekday` days). Compute `to` as the target-zone midnight three local days after `from`, resolving each date's offset separately so DST transitions cannot create a gap or overlap.

**Verify**: `pnpm run test:functions` → existing vitest suite passes after the helper change.

### Step 2: Use the Chicago-local half-open weekend window and formatting

In `send-weekly-digest/index.ts`, replace the UTC calendar construction with:

```ts
const { from, to } = weekendWindowUtc(new Date(), "America/Chicago");
```

Keep `windowFrom` as the maximum of `now` and `from`; set `windowTo = to.toISOString()`. Treat the range as half-open `[windowFrom, windowTo)` and pair this with Step 3's SQL predicate.

In `splitDateTime`, pass `timeZone: "America/Chicago"` to both `toLocaleDateString` and `toLocaleTimeString`. Preserve all other formatting options.

**Verify**: `grep -n "getUTCDay\|setUTCHours" supabase/functions/send-weekly-digest/index.ts` → no output; `pnpm run test:deno` → all Deno tests pass.

### Step 3: Fix half-open range semantics and one-sided age scoring in a migration

Choose the next free `20260724NNNNNN` timestamp. Create the migration and paired rollback named in Scope. Do not edit `20260620030000_plan_events_for_user_range.sql`.

In the forward migration, `CREATE OR REPLACE FUNCTION public.plan_events_for_user_range(...)` using exactly the existing signature and return type. Copy the full current function body and make only these changes:

1. Replace the candidate predicate with:
   ```sql
   e.start_datetime >= p_date_from
   AND e.start_datetime < p_date_to
   ```
2. Replace the age ELSE distance branch with:
   ```sql
   ELSE GREATEST(0.0, 1.0 - (
     CASE
       WHEN e.age_min IS NOT NULL AND p_kid_age < e.age_min THEN
         (e.age_min - p_kid_age)::numeric
       WHEN e.age_max IS NOT NULL AND p_kid_age > e.age_max THEN
         (p_kid_age - e.age_max)::numeric
       ELSE 0
     END
   ) / 5.0)
   ```

Document that both-NULL bounds mean all ages and score 1.0 through the first CASE arm. The rollback must restore the `20260620030000` function body verbatim, including its inclusive range and previous age calculation.

**Verify**: `pnpm run db:start && pnpm run db:migrate && pnpm run db:test` → migration applies and all DB tests pass. Confirm the rollback exists with the identical timestamp prefix.

### Step 4: Decouple Telegram dispatch from Resend configuration

In `send-weekly-digest/index.ts`, remove the early return when `RESEND_API_KEY` is absent. Introduce:

```ts
const emailEnabled = resendApiKey !== "";
```

When false, emit the existing dry-run warning exactly once before the dispatch loop. Change the email branch to `if (user.digest_email && emailEnabled)`. Add `else if (user.digest_email)` to increment a new `email_skipped` summary counter. Do not change the Telegram branch. Add `email_skipped` to the response and cron summary shape.

**Verify**: `pnpm run test:deno` → Telegram-only/no-Resend regression passes and all Deno tests remain green.

### Step 5: Add boundary and regression coverage

Create `supabase/functions/_shared/zoned-time.test.ts` using vitest. Cover Friday selection from every weekday, representative CDT and CST Sundays, and exact 2026 DST transition windows for March 8 and November 1. Assert Friday and Monday UTC instants exactly and prove no one-hour gap or overlap.

Extend `send-weekly-digest_test.ts` so a Sunday 19:00 America/Chicago event is included, a Thursday 20:00 event is excluded, and a Telegram-only user receives a Telegram send when `RESEND_API_KEY` is missing. Assert `email_skipped` counts opted-in email users skipped for missing config.

Create `supabase/tests/plan_events_for_user_range_age.sql` following `supabase/tests/set_preferred_cities.sql`. Cover lower-bound-only, upper-bound-only, bounded, and both-NULL age ranges. Add half-open range cases: an event exactly at `p_date_to` is excluded and an event one second before is included.

**Verify**: `pnpm run test:functions && pnpm run test:deno && pnpm run db:test` → all suites pass, including the new DST, digest, and pgTAP cases.

## Test plan

- `_shared/zoned-time.test.ts`: every weekday-to-Friday mapping; Chicago CST/CDT offsets; both 2026 DST boundaries; exact `[Friday 00:00, Monday 00:00)` instants.
- `send-weekly-digest_test.ts`: Sunday-evening inclusion, Thursday-evening exclusion, Chicago display formatting, Telegram dispatch without Resend, and `email_skipped` accounting.
- `supabase/tests/plan_events_for_user_range_age.sql`: one-sided lower and upper bounds, bounded ages, both bounds NULL, and half-open upper boundary.
- Use existing injected Telegram spies and Supabase test stubs; do not add real network calls.
- Final verification: `pnpm run check`, `pnpm run lint`, `pnpm run test:functions`, `pnpm run test:deno`, and `pnpm run db:test` all succeed.

## Done criteria

- [ ] Zoned weekend windows are Friday 00:00 through Monday 00:00 in America/Chicago and are DST-safe.
- [ ] `grep -n "getUTCDay\|setUTCHours" supabase/functions/send-weekly-digest/index.ts` returns no matches.
- [ ] Digest dates and times are explicitly formatted in `America/Chicago`.
- [ ] The RPC uses a half-open date range and correct one-sided age-distance scoring.
- [ ] The append-only migration has a paired rollback restoring the prior body.
- [ ] Sunday-evening events are included and Thursday-evening events are excluded by tests.
- [ ] Telegram-only delivery works without `RESEND_API_KEY`; skipped email is reported.
- [ ] All relevant Deno, vitest, DB, typecheck, and lint gates pass.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` row 031 is updated.

## STOP conditions

Stop and report back; do not improvise if:

- The live RPC body differs from `20260620030000_plan_events_for_user_range.sql` because another plan changed it. Rebase the full-function replacement rather than merging bodies by guesswork.
- The digest dispatch loop differs materially from the cited structure.
- The local DB is unavailable for pgTAP. Run the Deno and vitest suites and explicitly report the pgTAP gap; do not silently skip it.
- Correct weekend behavior would require per-event timezones or changing product timezone policy.
- Any step requires changing the RPC signature or return type; plan 035 owns the return-type change.

## Maintenance notes

- Plan 035 must be authored on top of this plan's post-fix RPC body and preserve both the half-open predicate and age-scoring correction.
- `zonedDayStartUtc` is also used by reminders, but reminder policy changes remain out of scope; reviewers should still check that existing reminder tests stay green.
- The product is intentionally single-zone. Revisit per-event formatting only if multi-region support is approved.
- Review the migration as a full-function replacement: only the two specified semantic changes are allowed.
