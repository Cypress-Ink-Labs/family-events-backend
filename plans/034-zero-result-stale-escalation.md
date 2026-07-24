# Plan 034: Route deterministic zero-result runs to stale escalation

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. Honor STOP conditions — do not improvise. When done, update your row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2f10101..HEAD -- supabase/functions/process-source-queue/lib/worker.ts supabase/functions/process-source-queue/lib/worker_test.ts supabase/functions/scrape-source/lib/process-source.ts supabase/functions/scrape-source/lib/process-source_test.ts`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `2f10101`, 2026-07-24

## Why this matters

The queue worker treats a successful deterministic extraction with zero events as an extraction error. It schedules retries and returns before the normal import/finalization path, so the only stale-source counter never increments. Empty deterministic sources can therefore retry to dead forever and be re-enqueued every cron tick. Separately, the final source-run and event-source writes ignore Supabase's returned errors, allowing the queue row to report success while persistence remains stale or stuck at `running`. Empty success must flow through normal finalization, and failed finalization writes must make otherwise successful results retryable.

## Current state

- `supabase/functions/process-source-queue/lib/worker.ts:374-386` checks deterministic mode and `events.length === 0`, then calls `markRunError`, schedules a retry, and returns early.
- `runDeterministicExtractionPhase` already distinguishes a real extraction error through its `error` field.
- `supabase/functions/scrape-source/lib/process-source.ts:167-208` safely accepts an empty array and returns a success result with `eventsFound: 0` after normal import/finalization.
- `process-source.ts:440` increments the stale counter only when `status === "success" && eventsFound === 0`.
- `process-source.ts:420-448` awaits updates to `source_runs` and `event_sources` in a `finally` block but does not inspect either returned `error`. Supabase query errors do not throw by default; the same file already documents this behavior around its audit insert.
- The worker's existing post-import branch retries results whose status is neither `success` nor `partial`. Reuse that path instead of adding a second retry mechanism.
- Use the existing worker and process-source test fixtures; preserve their dependency-injection patterns.

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
- `supabase/functions/process-source-queue/lib/worker.ts`
- The existing worker test file covering deterministic extraction (`worker_test.ts`; if the live filename differs, use that existing file only)
- `supabase/functions/scrape-source/lib/process-source.ts`
- `supabase/functions/scrape-source/lib/process-source_test.ts`

**Out of scope**:
- LLM fallback behavior
- Stale threshold values or stale-state schema
- Queue claim/reap mechanics
- Deterministic extractor implementation
- Retry/dead-letter policy beyond routing through the existing worker branch

## Git workflow

- Branch: `advisor/034-zero-result-stale-escalation`
- Commit per logical unit using Conventional Commits, for example `fix(functions): finalize empty deterministic scrapes`.
- Do NOT push or open a PR unless the operator instructs.

## Steps

### Step 1: Let deterministic empty success reach the import path

In `process-source-queue/lib/worker.ts`, narrow the early retry condition to:

```ts
source.extraction_mode === "deterministic" && deterministic.error
```

Do not include `deterministic.events.length === 0`. A successful empty result must call `importParsedSourceEvents` with an empty array and use the same success/finalization path as any other extraction.

Update the worker test that currently expects an empty deterministic result to retry. It must now assert `{ outcome: "succeeded", imported: 0 }`, prove the real import path was called with an empty array, and prove no retry was scheduled. Keep the real-error retry case unchanged.

**Verify**: focused worker tests pass; deterministic empty success calls the import path and deterministic `error` still schedules a retry.

### Step 2: Check both finalization update results

In the `process-source.ts` `finally` block, destructure errors from both updates:

```ts
const { error: runUpdateError } = await …
const { error: sourceUpdateError } = await …
```

For each error:

1. Call `logEdgeEvent("error", …)` with the failing write name and safe context.
2. Call `captureEdgeException` using the file's existing error-conversion convention.
3. If the result status before finalization was `success` or `partial`, change the returned result to `status: "error"` and set `errorMessage` to identify the failed `source_runs` or `event_sources` write.
4. If the scrape result was already `error`, preserve its original status and message; log the finalization error but never mask the root scrape failure.

If both writes fail, preserve the first finalization failure message deterministically while logging/capturing both. Do not throw from `finally`; the returned error status lets the worker's existing retry branch handle it.

**Verify**: focused `process-source_test.ts` cases show a `source_runs` update error converts success to returned status `error`, and an `event_sources` error after an existing scrape error preserves the original message.

### Step 3: Add stale-escalation and finalization regressions

Extend the existing tests with:

- Deterministic empty result → import path runs, queue row succeeds, no retry is scheduled.
- Deterministic thrown/returned extraction error → retry behavior is unchanged.
- Three consecutive successful empty deterministic imports → stale counter increments once per run and reaches the existing escalation threshold.
- `source_runs` update error after success → returned status `error` names that write.
- `event_sources` update error after success → returned status `error` names that write.
- Finalization error after a prior scrape error → original scrape message remains authoritative.

Use injected Supabase errors rather than real network or DB failures. Do not loosen existing assertions around queue outcomes.

**Verify**: `pnpm run test:deno` → all worker and process-source tests pass, including the three-run stale escalation.

### Step 4: Run the full relevant gates

Run the Deno suite first, then typecheck and lint. No migration or DB test is required because this plan changes no SQL contract.

**Verify**: `pnpm run test:deno && pnpm run check && pnpm run lint` → all commands exit 0.

## Test plan

- Worker tests distinguish empty successful extraction from actual deterministic extraction errors.
- Process-source tests inject each finalization write failure independently.
- A prior scrape error plus a finalization failure proves error-message precedence.
- A three-run empty sequence proves the stale counter becomes reachable, not merely that one empty run succeeds.
- Follow the existing dependency injection and fake Supabase chain in the two test files.
- Final verification: Deno, typecheck, and lint gates all pass.

## Done criteria

- [ ] Deterministic `events.length === 0` no longer triggers the worker's early retry branch.
- [ ] Empty deterministic success runs through `importParsedSourceEvents` and reports imported 0.
- [ ] Three consecutive empty successes reach the existing stale escalation.
- [ ] Both finalization updates capture and handle returned Supabase errors.
- [ ] A finalization failure converts only prior success/partial results to returned status `error`.
- [ ] Original scrape errors are never masked by finalization errors.
- [ ] Existing worker retry/dead-letter logic remains unchanged.
- [ ] `pnpm run test:deno`, typecheck, and lint pass.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` row 034 is updated.

## STOP conditions

Stop and report back; do not improvise if:

- `runDeterministicExtractionPhase` now sets `error` for empty successful results or otherwise changed its contract.
- The worker import call or outcome contract changed from the cited shape.
- Finalization writes moved outside `process-source.ts` or became transactional/throwing.
- The fix appears to require changing the stale threshold, queue schema, or retry policy.

## Maintenance notes

- Empty results are valid extraction outcomes; stale escalation is a finalization concern. Keep that boundary in future extractor changes.
- Supabase data operations generally return `{ error }` instead of throwing. New finalization writes must inspect the result explicitly.
- Reviewers should verify a secondary finalization failure never replaces an earlier scrape error.
- Plan ordering originally called out C18 before C6; this combined plan implements finalization handling and then routes empty success through it in one bounded change.
