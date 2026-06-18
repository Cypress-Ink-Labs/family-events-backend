# Plan 007: The LocalHop scraper fetches through the SSRF guard

> **Executor instructions**: Follow step by step. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/scrape-source/parsers/localhop.ts supabase/functions/_shared/guarded-fetch.ts`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (swaps `fetch` for the guarded wrapper; the guard adds redirect re-validation)
- **Depends on**: 001
- **Category**: security
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

Every scraper fetch in `scrape-source/lib/*` goes through `guardedFetch` (SSRF-safe: resolves + range-checks
the URL and re-validates every redirect hop). The LocalHop parser is the **one exception** — it calls plain
`fetch()` on a URL derived from `source.url`. `source.url` is admin-configured (not end-user input), so the
real exploitability is low — but the inconsistency means a misconfigured/compromised source URL, or a
LocalHop endpoint that 30x-redirects, can reach an internal/loopback/metadata address with no guard. This
closes the gap and makes the SSRF posture uniform across all scraper fetches.

## Current state

`supabase/functions/scrape-source/parsers/localhop.ts:191-216`:

```ts
async fetchArtifact(source) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(buildLocalHopUrl(source.url), {
      headers: { Accept: "application/json", "X-Parse-Application-Id": LOCALHOP_APP_ID },
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timeoutId);
    if (err instanceof Error && err.name === "AbortError") {
      throw new Error(`localhop: fetch timed out after ${FETCH_TIMEOUT_MS}ms`);
    }
    throw err;
  }
  clearTimeout(timeoutId);
  if (!response.ok) throw new Error(`localhop: fetch failed with HTTP ${response.status}`);
  // ...
}
```

The guard to use — `supabase/functions/_shared/guarded-fetch.ts`:
```ts
export async function guardedFetch(rawUrl: string, init: RequestInit = {}, opts: GuardedFetchOptions = {}): Promise<Response>
// resolves+range-checks rawUrl, fetches with redirect:"manual", re-validates each Location hop (default 3).
// Throws SsrfRejectedError on a private/loopback/link-local/reserved target. Caller's init.redirect is ignored.
```

How the sibling parsers use it (`scrape-source/lib/process-source.ts:132-156`): `guardedFetch(url, { headers, signal })`.

## Steps

### Step 1: Route the LocalHop fetch through `guardedFetch`

- Add `import { guardedFetch } from "../../_shared/guarded-fetch.ts";` at the top of `localhop.ts`
  (match the relative depth — `parsers/` is one level below `scrape-source/`, so `../../_shared/...`).
- Replace `await fetch(buildLocalHopUrl(source.url), { headers, signal })` with
  `await guardedFetch(buildLocalHopUrl(source.url), { headers: {...}, signal: controller.signal })`.
- Keep the `AbortController`/timeout exactly as-is (`guardedFetch` forwards `init`, including `signal`).
- Add a `catch` branch (or extend the existing one) so an `SsrfRejectedError` produces a clear message,
  e.g. `throw new Error(\`localhop: blocked by SSRF guard: ${err.message}\`)`. Import `SsrfRejectedError`
  from the same module if you branch on it.

**Verify**: `pnpm run check` exits 0; `grep -n "await fetch(" supabase/functions/scrape-source/parsers/localhop.ts`
returns nothing.

### Step 2: Test

If `localhop.ts` has a test (`localhop_test.ts` / `rss_test.ts` are siblings — check
`scrape-source/parsers/`), add/adjust a case that injects a fake `fetch`/resolver such that the URL
resolves to a private IP and asserts the parser surfaces an SSRF rejection. If `guardedFetch` is hard to
stub at the parser level, at minimum keep the happy-path test green and add a `guarded-fetch.test.ts`
covering the redirect re-validation path (see plan 001 / TEST-06 — a guarded-fetch test is independently
valuable): a 302 → private-IP `Location` must throw `SsrfRejectedError`; a 302 → public `Location` must follow.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Typecheck | `pnpm run check` | exit 0 |
| Tests | `deno test` (cwd `supabase/functions`) and `pnpm -C supabase/functions exec vitest run` | pass |

## Scope

**In scope:** `supabase/functions/scrape-source/parsers/localhop.ts`, its test, optionally a new
`_shared/guarded-fetch.test.ts`.
**Out of scope:** the other parsers (already guarded), `guarded-fetch.ts` itself (don't change the guard's
behavior — only add tests).

## Done criteria

- [ ] `localhop.ts` uses `guardedFetch`, not bare `fetch`
- [ ] `pnpm run check` exits 0
- [ ] A test exercises the SSRF-rejection path (in `localhop` and/or a new `guarded-fetch.test.ts`)
- [ ] Only in-scope files modified
- [ ] `plans/README.md` row for 007 updated

## STOP conditions

- `buildLocalHopUrl(source.url)` produces a non-HTTP scheme or a templated host that `guardedFetch`'s
  resolver can't handle — report; do not weaken the guard to accommodate it.
- The LocalHop API legitimately lives behind a redirect chain longer than `guardedFetch`'s default 3 hops
  — bump `maxRedirects` via the third arg `{ maxRedirects: N }` and note why, rather than reverting to `fetch`.

## Maintenance notes

- Reviewer: confirm `signal`/timeout still works through `guardedFetch` (it forwards `init`).
- Any new scraper parser added later must use `guardedFetch`. Consider a lint/grep guard test that fails
  on bare `fetch(` inside `scrape-source/parsers/` — deferred out of this plan.
