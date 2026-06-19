# Plan 022: Test the notify-path edge functions (send-push, notify-email, send-reminders)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5daa274..HEAD -- supabase/functions/send-push supabase/functions/notify-email supabase/functions/send-reminders`
> If any in-scope file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch, treat
> it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

The notify path delivers reminders, change notifications, and transactional
email — user-visible, run unattended by cron, and integrating three external
providers (Resend, web-push/VAPID, APNS, FCM). Today `send-push` has tests for
`parsePayload` only; its handler (subscription fetch → platform dispatch → prune
on 410/404) is untested. `notify-email` (6 payload kinds, each a different Resend
template) and `send-reminders` (day-window query, dedup, fan-out) have **no
tests**. A regression in template variables, the dedup key, or the prune logic
ships silently. This plan adds focused tests for the testable units.

## Current state

- `supabase/functions/send-push/send-push.test.ts` — Deno-native (`Deno.test(...)`),
  re-implements `parsePayload` locally and tests only that. The handler
  (`supabase/functions/send-push/index.ts:323` `serveServiceRoleJson(...)`) reads
  vault secrets, then dispatches per platform and prunes dead subscriptions —
  untested.
- `supabase/functions/notify-email/index.ts` — handles payload kinds
  (`admin_request`, `request_approved`, `request_rejected`, `welcome`,
  `community_event_approved/rejected`); posts to Resend with per-kind template id
  + variables. No test file.
- `supabase/functions/send-reminders/index.ts` — builds day windows via
  `zonedDayStartUtc` (`_shared/zoned-time.ts`), dedups targets by a
  `user:event:type` key (`index.ts:220`), inserts in-app notifications
  (`:248`), sends email + calls `send-push`. No test file.

### Test conventions (match these exactly)

- Function-directory tests are **Deno-native**: `Deno.test("...", () => { ... })`,
  named `<name>_test.ts` or `<name>.test.ts`, run with `deno test` from
  `supabase/functions/`. See `supabase/functions/send-push/send-push.test.ts` and
  `supabase/functions/events-api/events-api_test.ts` for the established style
  (local re-implementation or import of the pure unit under test; assertions via
  `jsr:@std/assert` / `Deno.test`).
- Pure `_shared/*.test.ts` modules run under **vitest** (`vitest.config.ts`
  includes `_shared/**/*.test.ts`) — do NOT put new function tests there.
- Test the **pure, deterministic units**, not live network. Where a function
  mixes I/O and logic, extract or target the pure helper (dedup key, window
  computation, template-variable builder, prune decision). If a unit is currently
  inline and untestable without a refactor, lift it into a small exported helper
  in that function's dir — that is the only source change allowed (see Scope).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Lint | `pnpm run lint` | exit 0 |
| Run a Deno test file | `cd supabase/functions && deno test --allow-env --allow-read <relpath>` | all pass |
| All Deno function tests | `pnpm run test:deno` | all pass |
| Guards (no DB) | `pnpm run workspace:test` | all pass |
| Typecheck | `pnpm run check` | exit 0 |

(Full `pnpm run test` also runs `db:test`, which needs a local Supabase — not
required for this tests-only plan.)

## Scope

**In scope**:
- `supabase/functions/send-push/*_test.ts` (extend/add)
- `supabase/functions/notify-email/*_test.ts` (create)
- `supabase/functions/send-reminders/*_test.ts` (create)
- Minimal, behavior-preserving extraction of an inline pure helper into the SAME
  function's directory ONLY when needed to make a unit testable (e.g. a
  `buildTemplateVars(payload)` or `dedupeTargets(rows)` export). If a helper
  extraction would change runtime behavior, STOP.

**Out of scope**:
- Live network / real Resend / real APNS-FCM calls.
- Any change to `_shared/*` (those have their own vitest suites).
- `send-weekly-digest`, `events-feed` — already have tests; do not touch.
- The notification-queue processed-mark behavior (intentional at-most-once — see plans/README rejected notes).

## Git workflow

- Branch: `advisor/022-notify-path-function-tests`
- Conventional Commits, e.g. `test(functions): cover notify-path units (send-push/notify-email/send-reminders)`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: send-push prune + platform-routing tests
Identify the pure decision points in `send-push/index.ts`: the 410/404 → prune
decision and the platform selection (web/APNS/FCM) from a subscription row. If
they are inline, extract minimal pure helpers (e.g. `shouldPrune(status)`,
`platformOf(subscription)`) and export them. Add Deno tests asserting: 410 and
404 → prune true; 2xx → prune false; each subscription shape routes to the right
platform.
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read send-push/` → pass.

### Step 2: notify-email payload-kind tests
For each payload kind, assert the correct Resend template id + the variable set
(and that escaping/trimming helpers behave). Mock `fetch` (assign a stub to
`globalThis.fetch` within the test and restore after) to assert the POST body
shape without hitting the network; also cover the no-`RESEND_API_KEY` soft path.
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read notify-email/` → pass.

### Step 3: send-reminders window + dedup tests
Target `zonedDayStartUtc` usage and the dedup logic (`user:event:type` key).
Assert: two rows with the same key collapse to one target; the day-window bounds
are computed for a fixed `now` + tz; in-app notification rows are shaped
correctly. Mock `fetch`/`send-push` calls as in Step 2.
**Verify**: `cd supabase/functions && deno test --allow-env --allow-read send-reminders/` → pass.

### Step 4: full gates
**Verify**: `pnpm run lint` → 0; `pnpm run test:deno` → all pass; `pnpm run check` → 0; `pnpm run workspace:test` → all pass.

## Test plan

- New Deno test files per Scope. Cases: send-push (prune 410/404/2xx, platform
  routing), notify-email (each of the 6 kinds → template id + vars, soft-fail
  no-key), send-reminders (dedup collapse, window bounds, in-app row shape).
- Pattern: `send-push/send-push.test.ts`, `events-api/events-api_test.ts`.
- Verification: `pnpm run test:deno` includes the new files and passes.

## Done criteria

- [ ] New `*_test.ts` exist for send-push (handler units), notify-email, send-reminders
- [ ] `pnpm run test:deno` passes including the new files
- [ ] `pnpm run lint` and `pnpm run check` exit 0
- [ ] Any source change is a behavior-preserving helper extraction in the same function dir (`git diff` shows no logic change), or none
- [ ] `plans/README.md` status row updated

## STOP conditions

- Making a unit testable would require changing runtime behavior or touching `_shared`.
- A function's live code diverges from the excerpts (drift since `5daa274`).
- A test can only pass by hitting a real external provider (network) — stop; mock instead.
- `deno test` reveals an apparent bug: record `file:line` and STOP (no source fixes beyond the allowed extraction).

## Maintenance notes

- These pin notify-path behavior (templates, dedup, prune). When a template/var
  changes intentionally, update the test in the same PR.
- Reviewer: confirm no test performs real network I/O and any extraction is
  behavior-preserving.
- Deferred: full handler integration tests (vault + multi-provider dispatch) —
  larger, needs a mocked Supabase + fetch harness; revisit if the dispatch logic churns.
