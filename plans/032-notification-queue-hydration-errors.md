# Plan 032: Fail notification-queue runs on hydration errors

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. Honor STOP conditions — do not improvise. When done, update your row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2f10101..HEAD -- supabase/functions/process-notification-queue/index.ts supabase/functions/process-notification-queue/process-notification-queue_test.ts`
> If either in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `2f10101`, 2026-07-24

## Why this matters

The notification queue discards errors from event, profile, and preference hydration reads. A failed preference query falls through to an opt-in default and can email users who opted out; failed event or profile reads make entries look incomplete, after which they are marked processed and permanently dropped. The final mark-processed update also reports `ok: true` even when persistence fails. Hydration failures must abort before any side effect, while the existing at-most-once claim/delivery ordering remains unchanged.

## Current state

- `supabase/functions/process-notification-queue/index.ts:129-159` destructures only `data` from three Supabase queries:
  ```ts
  const { data: events } = await supabase …
  const { data: profiles } = await supabase …
  const { data: prefs } = await supabase …
  ```
  None checks the returned `error`.
- At approximately line 207, a genuinely missing preference row defaults to `{ change_email: true, change_push: true }`. Preserve this product behavior for successful queries with no row.
- At approximately lines 209-212, missing event/profile data causes the queue entry to be skipped and later marked processed. That is acceptable only when the successful hydration result truly lacks the row, not when the query failed.
- At approximately lines 380-408, an error from the final `processed=true` update is logged but the handler still returns `ok: true` and counts the entries as processed.
- Round 2 explicitly retained the current at-most-once tradeoff: delivery happens before the final processed marker, and retrying after a side effect could duplicate email/push. Do not redesign claim or delivery ordering.
- `process-notification-queue_test.ts` already has a stub-Supabase harness. Extend it; do not introduce a second mocking convention.

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
- `supabase/functions/process-notification-queue/index.ts`
- `supabase/functions/process-notification-queue/process-notification-queue_test.ts`

**Out of scope**:
- Claim ordering, retry semantics, or the settled at-most-once design
- Email, in-app, or push delivery implementations
- Other notification Edge Functions
- Queue schema or database migrations
- Fan-out concurrency; that is a separate deferred performance finding

## Git workflow

- Branch: `advisor/032-notification-queue-hydration-errors`
- Commit per logical unit using Conventional Commits, for example `fix(functions): fail notification hydration errors`.
- Do NOT push or open a PR unless the operator instructs.

## Steps

### Step 1: Fail before side effects when hydration queries fail

In `process-notification-queue/index.ts`, capture both `data` and `error` from the events, profiles, and preferences hydration queries. Immediately after each query, check its error before constructing maps or entering the delivery loop.

On any hydration error:

1. Call `logCronRunEvent` at level `error`.
2. Name the failing stage exactly as `events`, `profiles`, or `preferences` and include the safe error message already exposed by Supabase.
3. Throw the error so the handler aborts before email, in-app, or push side effects.

Do not treat an empty successful result as an error. Keep the current opt-in default only for a genuinely missing preference row after a successful query.

**Verify**: `pnpm run test:deno` → the new events, profiles, and preferences query-error cases throw and show zero delivery attempts; all existing notification tests pass.

### Step 2: Report mark-processed persistence failures honestly

Keep the existing delivery and processed-update order. When the final `processed=true` update returns `updateErr`:

- Log the run summary through `logCronRunEvent` at level `error`.
- Return `ok: false`.
- Report `processed: 0` rather than claiming the batch was persisted as processed.
- Add `processed_update_failed: true` and the update error message to the result and logged summary.
- Do not throw: side effects may already have happened, and the current at-most-once policy intentionally avoids an automatic full retry that would duplicate them.

On a successful update, preserve the existing response shape and counts; omit or set the new flag false consistently with the local response conventions.

**Verify**: `pnpm run test:deno` → an injected mark-processed update error returns `ok: false`, `processed: 0`, and `processed_update_failed: true` without throwing; success cases are unchanged.

### Step 3: Add focused regression tests

Extend `process-notification-queue_test.ts` using its existing stub-Supabase pattern. Add cases for:

- Preferences query error: handler throws; zero email, in-app, and push sends.
- Events query error: handler throws; zero sends.
- Profiles query error: handler throws; zero sends.
- Successful preferences query with no row: existing default-send behavior remains.
- Final mark-processed update error: no exception, but response is `ok: false`, has `processed_update_failed: true`, includes the message, and does not claim processed rows.

Ensure each query-specific failure is injected at the correct chain stage rather than via a global failure that cannot prove stage handling.

**Verify**: `pnpm run test:deno` → all notification-queue tests, including the five regressions above, pass.

## Test plan

- Follow `supabase/functions/process-notification-queue/process-notification-queue_test.ts`'s existing Supabase and delivery-spy setup.
- Prove hydration failures cause no delivery side effects and leave entries retryable.
- Prove a successful empty preference result retains the existing default behavior.
- Prove a post-delivery persistence error is reported honestly without changing at-most-once semantics.
- Final verification: `pnpm run test:deno`, `pnpm run check`, and `pnpm run lint` all succeed.

## Done criteria

- [ ] Every events/profiles/preferences hydration query captures and checks `error`.
- [ ] `grep -n "const { data: events }\|const { data: profiles }\|const { data: prefs }" supabase/functions/process-notification-queue/index.ts` returns no matches.
- [ ] Any hydration error aborts before all delivery side effects.
- [ ] A successful missing preference row still defaults to the existing send behavior.
- [ ] Mark-processed failure returns `ok: false`, `processed: 0`, and `processed_update_failed: true` with the error message.
- [ ] The at-most-once claim/delivery ordering is unchanged.
- [ ] `pnpm run test:deno`, typecheck, and lint pass.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` row 032 is updated.

## STOP conditions

Stop and report back; do not improvise if:

- The handler's hydration or finalization structure differs materially from the cited lines.
- The existing test harness cannot simulate errors for individual query stages. Report this limitation rather than replacing the harness.
- Correct handling appears to require moving delivery before/after claim or changing retry semantics.
- A change requires a database migration or edits to another notification function.

## Maintenance notes

- A hydration error is different from a successful empty result. Preserve that distinction in future query refactors.
- The opt-in default for a missing preference row is an existing product decision, not error fallback.
- The processed-update result is intentionally non-throwing because side effects may have occurred. Reviewers should verify the response is honest without reintroducing automatic duplicate delivery.
- Notification fan-out concurrency remains a separate performance plan; do not combine it with this correctness fix.
