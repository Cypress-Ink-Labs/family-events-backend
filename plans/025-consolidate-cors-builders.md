# Plan 025: Consolidate CORS onto one module with explicit public-vs-allowlist intent

> **Executor instructions**: Follow step by step; run every verification command
> and confirm before moving on. STOP conditions halt you. Update `plans/README.md`
> when done.
>
> **Drift check (run first)**:
> `git diff --stat 5daa274..HEAD -- supabase/functions/_shared/cors.ts supabase/functions/_shared/http.ts`
> On a mismatch vs the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

There are two `buildCorsHeaders` functions with different, silently-divergent
semantics. `_shared/cors.ts` allowlists the origin (+`Vary: Origin`) and OMITS
the header for non-allowlisted origins — the production-safe posture for
browser/auth endpoints. `_shared/http.ts` defaults to `Access-Control-Allow-Origin: *`
regardless of origin. A new function picks one by import and can land the open
default by accident. Plan 006 standardized on `cors.ts`, but `http.ts`'s builder
and several inline `corsHeaders = { "...": "*" }` objects remain. This plan makes
the choice explicit: one module, two clearly-named builders, every function
opted into the posture it actually wants — removing the footgun without changing
any endpoint's current behavior.

## Current state

`supabase/functions/_shared/cors.ts:37-50` — allowlist builder:
```ts
export function buildCorsHeaders(allowedOrigin: string | null, methods: string[] = ["POST", "OPTIONS"]) {
  const headers = { Vary: "Origin", "Access-Control-Allow-Methods": methods.join(", "),
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey" }
  if (allowedOrigin) headers["Access-Control-Allow-Origin"] = allowedOrigin
  return headers
}
```
plus `resolveAllowedOrigin(origin)` (`:21`) and `DEFAULT_ALLOWED_ORIGINS` (`:5`).

`supabase/functions/_shared/http.ts:9-15` — open builder (TO BE RETIRED):
```ts
export function buildCorsHeaders(options: CorsOptions = {}) {
  return { "Access-Control-Allow-Origin": options.origin ?? "*", ... }
}
```
`http.ts` ALSO exports `jsonResponse`, `errorJson`, `optionsResponse`,
`methodNotAllowed`, `parseJsonObject`, `mergeHeaders` — **keep all of those**;
only `buildCorsHeaders` (+ the now-unused `CorsOptions`/`DEFAULT_ALLOW_HEADERS` if
they become dead) is removed.

Callers to migrate (find them all yourself — these are leads):
- Functions importing `buildCorsHeaders` from `_shared/http.ts` (e.g. `share-og`).
- Functions with an INLINE cors object (e.g. `backfill-event-enrichment/index.ts:17`,
  `notify-email/index.ts:17`, `events-api/index.ts:30`).
Find them all: `grep -rn "buildCorsHeaders\|Access-Control-Allow-Origin" supabase/functions --include='index.ts'`.

## The two postures (classification rule — preserve current behavior)

- **Public read endpoints** that currently serve `*` to any origin — `events-api`,
  `share-og`, `sitemap`, `events-feed` (and any other that today returns `"*"`).
  These KEEP an open `*` response, via a NEW explicit helper.
- **Allowlisted endpoints** (browser/auth-invoked) — already use, or should use,
  `cors.ts`'s allowlist builder with `resolveAllowedOrigin(req.headers.get("origin"))`.

Do NOT change which posture a function has — only make it explicit and shared. If
a function's current posture is ambiguous, KEEP its current literal behavior and
note it.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `pnpm run check` | exit 0 |
| Lint | `pnpm run lint` | exit 0 |
| Deno tests | `pnpm run test:deno` | all pass |
| Guards | `pnpm run workspace:test` | all pass |
| Format check | `pnpm run format:check` | exit 0 |

## Scope

**In scope**:
- `supabase/functions/_shared/cors.ts` — add `export function buildPublicCorsHeaders(methods?: string[])` returning `{ "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": ..., "Access-Control-Allow-Headers": ... }` (the documented open posture, no `Vary`).
- `supabase/functions/_shared/http.ts` — remove `buildCorsHeaders` (+ now-dead `CorsOptions`/`DEFAULT_ALLOW_HEADERS` if unused). Keep everything else.
- The caller functions' `index.ts` — replace the http.ts import / inline cors object with the appropriate `cors.ts` builder (`buildPublicCorsHeaders()` for public, `buildCorsHeaders(resolveAllowedOrigin(origin))` for allowlisted).

**Out of scope**:
- Changing any endpoint's effective CORS posture (public stays public, allowlisted stays allowlisted).
- The non-CORS exports of `http.ts`.
- `_shared/cors.ts`'s `DEFAULT_ALLOWED_ORIGINS` list contents.

## Git workflow

- Branch: `advisor/025-consolidate-cors-builders`
- Conventional Commits, e.g. `refactor(functions): consolidate CORS onto _shared/cors.ts`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Add the explicit public helper to cors.ts
Add `buildPublicCorsHeaders(methods = ["GET", "OPTIONS"])` returning the `*`
posture. Export it. (Keep it next to `buildCorsHeaders` with a doc comment: "use
ONLY for intentionally-public, unauthenticated read endpoints".)
**Verify**: `pnpm run check` → 0.

### Step 2: Migrate each caller
For every function found in the grep: if it currently serves `*` (public read),
import + use `buildPublicCorsHeaders()`; otherwise use
`buildCorsHeaders(resolveAllowedOrigin(req.headers.get("origin")), [...])`.
Remove inline cors objects and http.ts `buildCorsHeaders` imports. Preserve each
function's methods list and OPTIONS handling.
**Verify**: `grep -rn "Access-Control-Allow-Origin" supabase/functions --include='index.ts'` → only inside `_shared/cors.ts` (no inline objects left); `grep -rn "buildCorsHeaders" supabase/functions/_shared/http.ts` → no match.

### Step 3: Remove the http.ts builder
Delete `buildCorsHeaders` (+ dead `CorsOptions`/`DEFAULT_ALLOW_HEADERS`) from
`http.ts`. Keep `jsonResponse`/`errorJson`/`optionsResponse`/`methodNotAllowed`/`parseJsonObject`/`mergeHeaders`.
**Verify**: `pnpm run check` → 0 (no broken imports); `pnpm run knip` → no new unused-export hints.

### Step 4: full gates
**Verify**: `pnpm run lint` → 0; `pnpm run format:check` → 0; `pnpm run test:deno` → pass; `pnpm run workspace:test` → pass.

## Test plan

- No behavior change → existing tests must stay green. If `events-api`/`share-og`
  have CORS assertions in their `_test.ts`, confirm they still pass (same `*`).
- Optionally add a tiny `_shared/cors.test.ts` (vitest — `_shared` is the vitest
  scope) asserting `buildPublicCorsHeaders()` returns `*` and `buildCorsHeaders(null)`
  omits the origin header. Pattern: existing `_shared/*.test.ts`.
- Verification: `pnpm run test:deno` + (if added) the vitest `_shared` run pass.

## Done criteria

- [ ] `_shared/http.ts` no longer exports `buildCorsHeaders`; its other exports remain
- [ ] No `index.ts` declares an inline `Access-Control-Allow-Origin` object
- [ ] Every migrated function uses a `_shared/cors.ts` builder matching its prior posture (public `*` vs allowlist)
- [ ] `pnpm run check`, `pnpm run lint`, `pnpm run format:check` exit 0; `pnpm run test:deno` + `pnpm run workspace:test` pass; `pnpm run knip` shows no new hints
- [ ] `plans/README.md` status row updated

## STOP conditions

- A function's current CORS posture is genuinely ambiguous and you cannot tell whether it should be public or allowlisted — STOP and report rather than guess (wrong choice = either CORS breakage or an over-permissive endpoint).
- Removing `http.ts` `buildCorsHeaders` breaks an import you can't cleanly retarget — STOP.
- Live `cors.ts`/`http.ts` diverge from the excerpts (drift since `5daa274`).

## Maintenance notes

- After this, there is ONE CORS module with two intentionally-named builders;
  new functions must pick `buildPublicCorsHeaders` (open) or `buildCorsHeaders`
  (allowlist) explicitly — no silent `*` default.
- Reviewer: verify NO endpoint's effective `Access-Control-Allow-Origin` changed
  vs `main` (diff the literal header each function returns).
