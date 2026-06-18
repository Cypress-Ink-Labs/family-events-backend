# Plan 010: process-notification-queue batches push delivery instead of one invoke per user

> **Executor instructions**: Follow step by step. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/process-notification-queue supabase/functions/send-push`

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (changes the send-push call contract / batching; must not drop or double-send any user)
- **Depends on**: 001
- **Category**: perf
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

`process-notification-queue` processes change notifications and, per queue entry, makes a **separate HTTP
invocation** to the `send-push` edge function (one `fetch` per user). Emails are necessarily per-user
(personalized templates), so they stay one-per-user — but the push fan-out is pure overhead: when many
users are notified about the same event change (cancellation, time change), that's N edge-function
round-trips where one batched invocation carrying N user_ids would do. Each invoke also has a timeout and
failure path, so N invokes multiply latency and partial-failure surface. Batching the push path cuts
round-trips and makes the worker finish more of its queue within the wall-clock budget.

> **Scope note (corrects an over-broad audit claim):** the email path is *not* batchable into one Resend
> call here, because each email is personalized (`USERNAME`, per-user `EVENT_*` template vars) and goes to
> a distinct recipient. Leave email as one-send-per-user. This plan is about the push fan-out only.

## Current state

`supabase/functions/process-notification-queue/index.ts:172-313` — inside the per-entry loop, push is sent
by invoking `send-push` once per entry:

```ts
// Send push if user wants change push
if (userPrefs.change_push) {
  try {
    const pushResponse = await fetch(`${supabaseUrl}/functions/v1/send-push`, {
      method: "POST",
      headers: { Authorization: `Bearer ${serviceRoleKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: entry.user_id, title: notifTitle, body: summary, url: eventUrl }),
      signal: AbortSignal.timeout(PUSH_TIMEOUT_MS),
    });
    if (pushResponse.ok) {
      const result = await pushResponse.json().catch(() => ({})) as { sent?: number };
      sentPush += result.sent ?? 0;
    } else { failedPush++; }
  } catch (err) { /* log + failedPush++ */ }
}
```

Each entry carries its own `notifTitle`/`summary`/`eventUrl` (derived from the entry's event + change),
so the natural batching unit is **(event_id, change_type)**: all users getting the *same* notification
text for the same event.

You must check what `send-push` accepts. Read `supabase/functions/send-push/index.ts` (and its handler):
it currently takes a single `{ user_id, title, body, url }`. To batch you will either (a) extend `send-push`
to also accept `{ user_ids: string[], title, body, url }` (preferred — keeps one source of truth for push
delivery), or (b) keep `send-push` per-user but stop re-invoking it per *queue entry* when entries share
identical payloads. Decide based on what `send-push` does internally (it likely loops subscriptions per user).

## Steps

### Step 1: Group entries by identical push payload

After computing `notifTitle`, `summary`, `eventUrl` per entry, build groups keyed by
`${entry.event_id}:${entry.change_type}` (the fields that determine the push text). Within a group,
collect the `user_id`s of users whose `userPrefs.change_push` is true. Keep the email + in-app inserts
exactly as they are today (per-user, inside the existing loop).

### Step 2: Extend send-push to accept a batch (recommended path)

In `send-push`, add support for `{ user_ids: string[], title, body, url }` alongside the existing
`{ user_id, ... }` shape. Internally, resolve subscriptions for all `user_ids` and send, returning a
total `{ sent: number }` (and ideally per-user failures). Preserve the existing single-`user_id` contract
for other callers (check who else calls send-push: `grep -rn "functions/v1/send-push" supabase/functions`).

### Step 3: Invoke send-push once per group

Replace the per-entry push `fetch` with one `fetch` per group, passing `user_ids`. Accumulate `sentPush`
from each group's response. Preserve the per-entry `failedPush` accounting semantics (if a group fails,
count the users in it). Keep `processedIds.push(entry.id)` for every entry regardless of push outcome
(unchanged — push failure must not block marking the entry processed, matching current behavior).

### Step 4: Tests

Extend the notification-queue test (it uses a `FakeSupabase`; add a fake `fetch`): assert that for a
batch where 3 users share one (event, change_type), `send-push` is invoked **once** with 3 `user_ids`
(or, under path (b), once total) rather than 3 times — while in-app notifications and emails are still
created per user. Add a case where two different events are in the same batch → two push groups.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Typecheck | `pnpm run check` | exit 0 |
| Tests | `pnpm -C supabase/functions exec vitest run process-notification-queue send-push` (+ `deno test`) | pass |
| Find send-push callers | `grep -rn "functions/v1/send-push" supabase/functions` | enumerate before changing contract |

## Scope

**In scope:** `process-notification-queue/index.ts`, `send-push` (if extending its contract), and the
tests for both.
**Out of scope:** the email path (stays per-user), the in-app notification inserts (stay per-user), queue
claiming/marking logic.

## Done criteria

- [ ] Push is invoked at most once per `(event_id, change_type)` group, not once per entry
- [ ] Every notified user still gets their in-app notification + (if opted in) personalized email
- [ ] No user is double-pushed and none is dropped (test covers a multi-user, multi-event batch)
- [ ] If `send-push` contract changed, all existing callers still work (enumerated + verified)
- [ ] `pnpm run check` exits 0; tests pass
- [ ] `plans/README.md` row for 010 updated

## STOP conditions

Stop and report if:
- `send-push` has per-user logic (e.g. per-user rate limits, per-user `url` deep-links) that makes a
  batch payload semantically different from N single sends — report; fall back to path (b) (dedup
  re-invocation) without changing the payload shape.
- Another caller depends on `send-push`'s exact single-user response shape and can't tolerate the
  extension — keep backward compatibility (accept both shapes) and note it.
- Queue entries that look like the same group actually carry different `change_detail`/text — re-key the
  group on whatever fully determines the push body.

## Maintenance notes

- Reviewer: the correctness risk is *dropping or doubling* a user. Scrutinize the grouping + the
  `sentPush`/`failedPush` accounting against the per-entry behavior it replaces.
- Deferred: batching the *email* path is not worth it (personalized) — explicitly out of scope.
