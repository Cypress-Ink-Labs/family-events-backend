# Plan 037: Add bounded concurrency to the review-queue worker

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. Honor STOP conditions — do not improvise. When done, update your row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2f10101..HEAD -- supabase/functions/process-event-review-queue/lib/worker.ts supabase/functions/process-event-review-queue/lib/worker_batch_test.ts supabase/functions/process-tag-queue/index.ts supabase/functions/event-review/config.ts`
> If any in-scope implementation or exemplar changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/036-memory-context-bulk-hydration.md` recommended first
- **Category**: perf
- **Planned at**: commit `2f10101`, 2026-07-24

## Why this matters

The review worker claims up to 60–100 rows but processes them serially. Each isolated LLM call can consume the provider's 30-second timeout against a 110-second worker budget, so timeout-heavy runs may finish only four claimed rows and repeatedly release/reclaim the rest. The tag queue already uses a bounded chunk plus `Promise.all` for the same class of work. Processing review rows three at a time keeps worst-case provider time near 90 seconds per chunk, uses the existing budget guard, and improves throughput without changing claim, retry, or per-row state semantics.

## Current state

- `supabase/functions/process-event-review-queue/lib/worker.ts:649-659` iterates claimed rows and awaits `processReviewQueueRow(deps, row)` one at a time.
- The loop checks `shouldStopBeforeStartingNextRow(elapsed)` before starting each row. On budget exhaustion it releases `claimed.slice(i)` and stops.
- The serial loop aggregates each returned per-row outcome into `summary`; preserve that accounting exactly.
- `processReviewQueueRow` handles normal per-row failure outcomes. An unexpected throw escapes the worker today; preserve that behavior rather than adding a catch.
- `supabase/functions/event-review/config.ts:65-70` sets the default provider timeout to 30 seconds. The worker wall budget is 110 seconds.
- `supabase/functions/process-tag-queue/index.ts:30-37` is the concurrency exemplar: fixed `BATCH_SIZE`/`CONCURRENCY`, chunk slices, and `Promise.all`. Copy this boring pattern; do not introduce a queue library or semaphore.
- `process-event-review-queue/lib/worker_batch_test.ts` already uses deferred promises for batch behavior. Extend that style to prove overlap deterministically.

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
- `supabase/functions/process-event-review-queue/lib/worker.ts`
- `supabase/functions/process-event-review-queue/lib/worker_batch_test.ts`

**Read-only exemplars/contracts**:
- `supabase/functions/process-tag-queue/index.ts`
- `supabase/functions/event-review/config.ts`

**Out of scope**:
- Claim size defaults, claim/reap SQL, or lease duration
- Provider timeout configuration
- `processReviewQueueRow`'s per-row state machine
- Retry, dead-letter, or release policy
- Memory-context implementation; plan 036 owns its N+1 reduction
- New concurrency libraries, semaphores, or adaptive tuning

## Git workflow

- Branch: `advisor/037-review-queue-bounded-concurrency`
- Commit per logical unit using Conventional Commits, for example `perf(functions): process review rows concurrently`.
- Do NOT push or open a PR unless the operator instructs.

## Steps

### Step 1: Confirm the provider concurrency limit and prerequisite posture

Verify the configured provider does not document a hard per-IP concurrency limit below three. Confirm plan 036 is landed or explicitly accepted as a temporary ordering exception; otherwise concurrency can multiply memory-context's current N+1 pressure.

**Verify**: provider configuration supports at least three concurrent requests, and `memory-context.ts` has the plan-036 bulk shape or the operator has recorded the exception. If the provider cap is two, use `REVIEW_CONCURRENCY = 2` and report that documented deviation.

### Step 2: Add a fixed three-row chunk size

Near the worker's existing batch/budget constants, add:

```ts
// 3 × 30s provider timeout = 90s, below the 110s worker budget.
const REVIEW_CONCURRENCY = 3;
```

Keep it module-local and fixed. Do not reuse claim size as concurrency or read a new environment variable.

**Verify**: `pnpm run check` → exit 0 with the new constant referenced by the loop.

### Step 3: Replace the serial loop with bounded chunks

Replace only the main serial loop in `worker.ts` with the existing tag-queue pattern:

1. Iterate by `i += REVIEW_CONCURRENCY`.
2. Before each chunk, compute elapsed time and call `shouldStopBeforeStartingNextRow(elapsed)` once.
3. If the budget guard stops, release `claimed.slice(i)` exactly as the serial loop releases its unstarted suffix; do not include rows from completed chunks.
4. Otherwise take `const chunk = claimed.slice(i, i + REVIEW_CONCURRENCY)`.
5. Run:
   ```ts
   const results = await Promise.all(
     chunk.map((row) => processReviewQueueRow(deps, row)),
   );
   ```
6. Aggregate each result into `summary` with the identical switch/branch/accounting used by the serial loop.

Do not catch around `Promise.all`: an unexpected `processReviewQueueRow` throw must escape exactly as it does today. Do not alter claim/release/reap, retries, or per-row outcomes.

**Verify**: focused batch tests show at most three active rows, row 2 starts before row 1 resolves, and six rows run as two chunks.

### Step 4: Protect budget-release and accounting semantics

Extend `worker_batch_test.ts` with deterministic deferred promises and an injected clock/budget seam already used by the file:

- For six claimed rows, hold the first chunk unresolved until all three starts are observed; assert active count is exactly three and row 4 has not started.
- Resolve chunk one; assert rows 4–6 then start.
- Trigger the budget guard after the first completed chunk; assert only `claimed.slice(3)` is released and no second-chunk row starts.
- Return mixed normal per-row outcomes within a chunk and assert summary counts equal the serial implementation's expected totals.
- Make one row unexpectedly throw and assert the worker rejects; do not assert graceful aggregation for an unhandled throw.

Keep tests schedule-independent by coordinating with deferred promises, not timers.

**Verify**: focused `worker_batch_test.ts` passes repeatedly and proves overlap, the concurrency ceiling, unstarted-suffix release, and unchanged summary accounting.

### Step 5: Add a synthetic throughput comparison

In the same test file, process a healthy 60-row synthetic batch with deterministic deferred/immediate work. Record the serial baseline in the test using the same fake work and assert the bounded implementation completes in fewer scheduling waves than the serial baseline. Do not assert wall-clock milliseconds, which would be flaky; compare maximum wave count or controlled virtual elapsed time.

**Verify**: the synthetic test demonstrates 20 three-row waves versus 60 serial waves (or an equivalent deterministic ratio) and passes without real network calls.

### Step 6: Run full relevant gates

Run the Deno worker suite, typecheck, and lint. No DB migration is involved.

**Verify**: `pnpm run test:deno && pnpm run check && pnpm run lint` → all commands exit 0.

## Test plan

- Deferred-promise tests prove rows overlap and concurrency never exceeds three.
- Six-row tests prove exactly two chunks and no row in the next chunk starts early.
- Budget tests prove only the unstarted suffix is released.
- Mixed per-row outcomes preserve the current summary counts.
- Unexpected throws still escape `Promise.all`, preserving failure semantics.
- A deterministic 60-row comparison proves fewer scheduling waves without flaky timing assertions.
- Final verification: Deno, typecheck, and lint gates all pass.

## Done criteria

- [ ] `REVIEW_CONCURRENCY` is fixed at 3, or 2 only with a documented provider limit below 3.
- [ ] Claimed rows execute in bounded chunks via `Promise.all`.
- [ ] The budget guard runs before each chunk and releases exactly the unstarted suffix.
- [ ] Claim, reap, release, retry, dead-letter, and per-row state logic are otherwise unchanged.
- [ ] Summary accounting matches the serial implementation for every normal per-row outcome.
- [ ] Unexpected per-row throws still escape.
- [ ] Tests prove overlap, ceiling, suffix release, and deterministic throughput improvement.
- [ ] `pnpm run test:deno`, typecheck, and lint pass.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` row 037 is updated.

## STOP conditions

Stop and report back; do not improvise if:

- The worker loop or `processReviewQueueRow` outcome contract changed from the cited structure.
- The LLM provider documents a hard per-IP concurrency limit below three; use two only as the documented contingency.
- The budget/release logic cannot distinguish started from unstarted rows after chunking.
- Correctness would require changing claim size, leases, retry, or per-row state behavior.
- Tests cannot prove overlap without timers because the deferred-promise seam was removed; report before inventing a new test harness.

## Maintenance notes

- Land plan 036 first when possible. Parallel review rows should not amplify per-match memory hydration queries.
- The fixed value is derived from current 30-second provider and 110-second worker budgets. Revisit together if either changes.
- Chunking limits concurrency but does not cancel in-flight rows when the budget expires. The guard only prevents starting the next chunk, matching current semantics.
- Reviewers should compare the summary aggregation block line-for-line with the old serial loop and reject unrelated state-machine edits.
