# Plan 008: scrape-source reliably triggers the queue even without EdgeRuntime

> **Executor instructions**: Follow step by step. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/scrape-source/index.ts`

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (adds an await on a fallback path; production behavior — where `EdgeRuntime` exists — is unchanged)
- **Depends on**: 001
- **Category**: bug
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

After enqueuing sources, `scrape-source` "kicks" the source-queue worker with a fire-and-forget promise.
It is only handed to `EdgeRuntime.waitUntil(...)` when `EdgeRuntime` exists. When it does **not** (local
`supabase functions serve`, tests, or any non-edge runtime), the promise is neither awaited nor tracked:
the function returns `200` immediately and the kick may never run (and any error is swallowed). So locally
the queue silently doesn't start, while the caller sees success — a confusing dev-time footgun. (Production
edge runtime is unaffected, hence P3.)

## Current state

`supabase/functions/scrape-source/index.ts:141-157`:

```ts
if (results.length > 0 && supabaseUrl && serviceRoleKey) {
  const kick = kickProcessSourceQueue(supabaseUrl, serviceRoleKey).catch((err) => {
    logEdgeEvent("warn", "source-queue kick failed",
      errorContext(err, { function: "scrape-source", stage: "kick-source" }));
  });
  if (typeof EdgeRuntime !== "undefined") {
    EdgeRuntime.waitUntil(kick);
  }
}
```

`EdgeRuntime` is declared at `index.ts:35-37` as possibly-undefined.

## Steps

### Step 1: Await the kick when EdgeRuntime is absent

Change the branch so the promise is always accounted for:

```ts
if (results.length > 0 && supabaseUrl && serviceRoleKey) {
  const kick = kickProcessSourceQueue(supabaseUrl, serviceRoleKey).catch((err) => {
    logEdgeEvent("warn", "source-queue kick failed",
      errorContext(err, { function: "scrape-source", stage: "kick-source" }));
  });
  if (typeof EdgeRuntime !== "undefined") {
    EdgeRuntime.waitUntil(kick);
  } else {
    await kick; // non-edge runtime (local/tests): await so the kick actually runs and errors surface
  }
}
```

The `.catch` already converts a rejection into a logged warning, so `await kick` cannot throw — the
function still returns its normal `200` response afterward. Production (EdgeRuntime present) keeps the
non-blocking `waitUntil` path.

**Verify**: `pnpm run check` exits 0.

### Step 2: Test

If `scrape-source` has an `index_test.ts`, add a case asserting that when `EdgeRuntime` is undefined and
`kickProcessSourceQueue` is stubbed, the stub is awaited (e.g. it has resolved by the time the response is
produced). If there is no entry-point test yet, add a minimal one stubbing `kickProcessSourceQueue` and
the supabase client. (TEST-02 in the audit flagged scrape-source's entry point as untested — a small test
here is independently valuable.)

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Typecheck | `pnpm run check` | exit 0 |
| Tests | `deno test` (cwd `supabase/functions`) | pass |

## Done criteria

- [ ] The `else { await kick }` branch exists; the `waitUntil` branch is unchanged
- [ ] `pnpm run check` exits 0
- [ ] A test covers the non-EdgeRuntime path (kick is awaited)
- [ ] Only `scrape-source/index.ts` (+ its test) modified
- [ ] `plans/README.md` row for 008 updated

## STOP conditions

- `kickProcessSourceQueue` can take a long time and awaiting it locally would exceed a sane request
  budget — report; you may instead guard with a short timeout, but do not leave it untracked.

## Maintenance notes

- Reviewer: confirm production path (EdgeRuntime defined) is byte-for-byte the same — only the `else` is new.
