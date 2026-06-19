# Plan 026: Batch the per-row DB writes/fetches in the cron pipeline

> **Executor instructions**: Follow step by step; run every verification command
> and confirm before moving on. STOP conditions halt you. Update `plans/README.md`
> when done.
>
> **Drift check (run first)**:
> `git diff --stat 5daa274..HEAD -- supabase/functions/scrape-source supabase/functions/send-reminders supabase/functions/process-notification-queue supabase/functions/process-tag-queue`
> On a mismatch vs the excerpts, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: none (coordinate with 023 — see Maintenance)
- **Category**: perf
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

Four hot loops issue one DB round-trip per item where a single batched call works,
multiplying latency and DB load on the cron pipeline as data grows. Each fix is a
local, behavior-preserving change.

## Current state (verified excerpts)

1. `supabase/functions/scrape-source/index.ts:80-91` — per-source status update inside the loop:
   ```ts
   for (const source of dueSources) {
     const enqueue = await enqueueSourceScrape(supabase, source.id, ...)
     await supabase.from("event_sources").update({ last_status: "pending" }).eq("id", source.id)
     results.push({ source_id: source.id, queue_id: enqueue.queue_id, deduped: enqueue.deduped })
   }
   ```
   → collect `source.id`s, issue ONE `update({last_status:"pending"}).in("id", ids)` after the loop. (Leave `enqueueSourceScrape` per-row — out of scope.)

2. `supabase/functions/send-reminders/index.ts:248` and
   `supabase/functions/process-notification-queue/index.ts:214` — per-target
   `user_notifications` insert inside the batch loop. → collect rows in an array,
   issue ONE `.insert([...rows])` per batch.

3. `supabase/functions/process-tag-queue/index.ts:206` — `fetchEventInputs(supabase, event_id)`
   (`.maybeSingle()` at `:64`) called once per row inside the parallel chunk loop
   (`:316-317`). → prefetch all rows' event inputs with one `.in("id", eventIds)`
   before the chunk loop, build a `Map<eventId, inputs>`, look up in `processOneRow`.

## CRITICAL behavior-preservation constraints

- **Counts / error visibility**: today each per-row insert checks its own error
  (e.g. `notifErr` → log warn → `inApp++` only on success). A batch insert returns
  ONE error for the whole array. Preserve the observable contract: on batch
  failure, log it (with the count) and keep the EXISTING queue-mark behavior —
  in `process-notification-queue`, `processedIds.push(entry.id)` happens
  regardless of the in-app insert result (intentional at-most-once; do NOT change
  that). The batch insert is a perf change to HOW rows are written, not to whether
  the queue entry is marked processed.
- **Ordering**: the `last_status` batch update must happen AFTER all enqueues (same as now). The tag-queue prefetch must complete BEFORE the first chunk runs.
- If batching would change which rows get marked processed/retried, STOP.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `pnpm run check` | exit 0 |
| Lint | `pnpm run lint` | exit 0 |
| Deno tests | `pnpm run test:deno` | all pass |
| Guards | `pnpm run workspace:test` | all pass |

## Scope

**In scope**: `scrape-source/index.ts`, `send-reminders/index.ts`,
`process-notification-queue/index.ts`, `process-tag-queue/index.ts` (the four
loops above) + any of their `*_test.ts` that need updating.

**Out of scope**: `enqueueSourceScrape` batching; the queue processed/retry/dead
policy; `_shared/*`; the notification at-most-once tradeoff.

## Git workflow

- Branch: `advisor/026-batch-per-row-db-ops`
- Conventional Commits, e.g. `perf(functions): batch per-row DB writes/fetches in cron pipeline`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: scrape-source batch status update
Collect ids during the loop; after the loop, one `update(...).in("id", ids)` (guard against empty array).
**Verify**: `pnpm run check` → 0; `cd supabase/functions && deno test --allow-env --allow-read scrape-source/` → pass.

### Step 2: batch user_notifications inserts (send-reminders + process-notification-queue)
Accumulate notification rows during the batch loop; one `.insert([...])` after.
Preserve the count/log contract and (in notification-queue) the unchanged
`processedIds` behavior.
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read send-reminders/ process-notification-queue/` → pass.

### Step 3: prefetch event inputs in process-tag-queue
Before the chunk loop, fetch all `event_id` inputs in one `.in(...)`; build a Map;
`processOneRow` reads from the Map (fallback to a single fetch only if an id is
missing from the prefetch, to preserve current resilience).
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read process-tag-queue/` → pass.

### Step 4: full gates
**Verify**: `pnpm run lint` → 0; `pnpm run check` → 0; `pnpm run test:deno` → pass; `pnpm run workspace:test` → pass.

## Test plan

- Update any affected `*_test.ts` to the batched shape; add a case asserting (a) a
  single batched call is issued for N items, (b) the empty-collection path issues
  no call, (c) counts/marks are unchanged. Pattern: existing function `_test.ts`.
- Verification: `pnpm run test:deno` passes.

## Done criteria

- [ ] scrape-source issues one `.in("id", ids)` status update (not per-source)
- [ ] send-reminders + process-notification-queue issue one batched `user_notifications` insert per batch
- [ ] process-tag-queue prefetches event inputs in one `.in(...)` before the chunk loop
- [ ] Queue processed/retry/dead behavior + notification counts unchanged
- [ ] `pnpm run check`/`lint` → 0; `pnpm run test:deno` + `workspace:test` pass
- [ ] `plans/README.md` status row updated

## STOP conditions

- Batching would change which rows are marked processed/retried/dead.
- A `.insert([...])` with mixed-success semantics can't preserve the current per-row count contract without a behavior change — STOP and report.
- Live code diverges from the excerpts (drift since `5daa274`).

## Maintenance notes

- **Coordinate with plan 023** (queue orchestration tests): if 023 lands first,
  the tag-queue prefetch must keep its scenarios green; if 026 lands first, 023's
  tests target the prefetch path.
- Reviewer: confirm the empty-array guards and that no per-row error contract was
  silently dropped (esp. the notification at-most-once mark).
