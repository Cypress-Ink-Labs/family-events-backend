# Plan 023: Characterization tests for the queue orchestration loops

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> "STOP conditions" item occurs, stop and report. When done, update the status
> row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5daa274..HEAD -- supabase/functions/process-tag-queue supabase/functions/process-event-review-queue`
> On a mismatch vs the "Current state" excerpts, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

`process-tag-queue` and `process-event-review-queue` are the workhorses of the
ingestion pipeline: they claim queued rows, run per-row work (LLM tagging /
review) under a concurrency + wall-clock budget, then mark each row
success / retry / dead-letter. Today only isolated helpers are tested
(`process-event-review-queue/lib/worker_test.ts`, queue-policy helpers); the
orchestration loop — claim, the `Promise.all` chunk runner, budget cut-off,
retry/backoff, and dead-lettering after max attempts — has no scenario coverage.
A regression in the retry/dead-letter transitions or the budget guard can stall
or silently drop the pipeline. This plan adds characterization tests for those
state transitions.

## Current state

`supabase/functions/process-tag-queue/index.ts`:
- `processOneRow(row)` calls `fetchEventInputs(supabase, event_id)` (`:206`,
  `.maybeSingle()` at `:64`), runs the LLM, then transitions the row.
- The batch runs in parallel chunks: `for (... i += CONCURRENCY) { await Promise.all(chunk.map(processOneRow)) }` (`:316-317`), with a wall-budget check before each chunk.
- Transition helpers issue `.update({...})` (`:104`, `:125`, `:140`) for
  success / retry / dead-letter.

`supabase/functions/process-event-review-queue/lib/worker.ts` + its
`worker_test.ts` (helpers only). The batch orchestration (claim → process →
mark) is not scenario-tested.

### Test conventions (match these)

- Deno-native tests (`Deno.test`), in the function's dir, run via `deno test`
  from `supabase/functions/`. See `process-event-review-queue/lib/worker_test.ts`
  for the established mocking style in this repo (inject a fake supabase-like
  client / fake row store; assert the resulting `.update` calls / transitions).
- Drive the loop with a **fake queue store**: an in-memory object exposing the
  `.from(...).select/update/...` chain the loop uses, returning canned rows and
  recording the transitions. Do not hit a real DB. The DB-integration layer is
  covered separately by `db:test` (needs local Supabase) — not in scope here.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Lint | `pnpm run lint` | exit 0 |
| Run a Deno test file | `cd supabase/functions && deno test --allow-env --allow-read <relpath>` | all pass |
| All Deno function tests | `pnpm run test:deno` | all pass |
| Typecheck | `pnpm run check` | exit 0 |

## Scope

**In scope**:
- `supabase/functions/process-tag-queue/*_test.ts` (add scenario tests)
- `supabase/functions/process-event-review-queue/*_test.ts` or `lib/*_test.ts` (add orchestration scenario tests)
- Minimal behavior-preserving export of the batch function if it isn't already
  importable for testing (e.g. export `processTagQueueBatch`); no logic change.

**Out of scope**:
- The LLM/classification internals (own `_shared` tests), the DB schema, `_shared/*`.
- Changing retry/backoff/dead-letter POLICY — tests must capture current behavior, not redefine it.

## Git workflow

- Branch: `advisor/023-queue-orchestration-tests`
- Conventional Commits, e.g. `test(functions): characterize tag/review queue orchestration`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Make the batch function importable (if needed)
Confirm `processTagQueueBatch` (and the review-queue equivalent) is exported. If
not, add an `export` (no logic change). Verify typecheck still passes.
**Verify**: `pnpm run check` → exit 0.

### Step 2: process-tag-queue scenarios
With a fake queue store + a stubbed per-row worker, cover: (1) happy path — N
rows all succeed → all marked success; (2) transient failure on one row → that
row marked retry (attempts++), others succeed; (3) row at max attempts fails →
marked dead-letter; (4) wall-budget exhausted before a chunk → remaining rows
released/left claimed per current behavior; (5) mixed batch.
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read process-tag-queue/` → pass.

### Step 3: process-event-review-queue scenarios
Same shape against the review worker: success, retry, dead-letter, budget cut-off.
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read process-event-review-queue/` → pass.

### Step 4: full gates
**Verify**: `pnpm run lint` → 0; `pnpm run test:deno` → pass; `pnpm run check` → 0.

## Test plan

- New Deno scenario tests per Scope, each asserting the exact transition the
  current code makes (success/retry/dead-letter) and the budget cut-off behavior.
- Pattern: `process-event-review-queue/lib/worker_test.ts`.
- Verification: `pnpm run test:deno` includes and passes the new files.

## Done criteria

- [ ] Scenario tests exist for both queue batch loops (happy/retry/dead-letter/budget)
- [ ] `pnpm run test:deno` passes including the new files
- [ ] `pnpm run lint` + `pnpm run check` exit 0
- [ ] Any source change is an `export` only (`git diff` shows no logic change)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The loop can't be driven without a real DB or without changing logic — STOP and report (it may need a small testability refactor out of this plan's scope).
- Live code diverges from the excerpts (drift since `5daa274`).
- A scenario reveals an apparent transition bug: record it and STOP (no policy changes here).

## Maintenance notes

- These lock the retry/dead-letter/budget contract. A deliberate policy change
  updates these tests in the same PR.
- Reviewer: confirm the fake store records transitions faithfully and no real DB/network is used.
- Pairs with plan 026 (which prefetches event inputs in process-tag-queue) — if
  026 lands first, the prefetch path must keep these scenarios green.
