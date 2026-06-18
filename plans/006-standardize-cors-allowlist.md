# Plan 006: All browser-facing handlers use the shared CORS allowlist

> **Executor instructions**: Follow step by step. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/_shared/cors.ts supabase/functions/_shared/service-role-handler.ts supabase/functions/_shared/admin-handler.ts supabase/functions/scrape-source/index.ts`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (tightens CORS; auth already gates data — but a too-narrow allowlist could break a
  legitimate browser origin, so verify the allowlist covers prod + localhost)
- **Depends on**: 001
- **Category**: security
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

There is a correct, allowlist-aware CORS module (`_shared/cors.ts`) that omits
`Access-Control-Allow-Origin` for non-allowlisted origins. But the two shared request handlers and the
`scrape-source` function don't use it:

- `service-role-handler.ts` hardcodes `Access-Control-Allow-Origin: *`.
- `admin-handler.ts` builds CORS via `http.ts#buildCorsHeaders`, which defaults to `*`.
- `scrape-source/index.ts` re-declares its **own** copy of `resolveAllowedOrigin` + `buildCorsHeaders` +
  `DEFAULT_ALLOWED_ORIGINS` — duplicating `cors.ts` (whose header comment literally says it was "Promoted
  from scrape-source/index.ts so weather/ and other functions share a single source of truth").

Reflecting `*` is defense-in-depth weakness (auth still gates data, and service tokens aren't
auto-attached by browsers, so real exploitability is low — hence LOW risk). Consolidating onto one
allowlist removes the divergence and the dead duplicate.

## Current state

`_shared/cors.ts` (the canonical module):

```ts
export const DEFAULT_ALLOWED_ORIGINS = [
  "https://family-events.org",
  "https://www.family-events.org",
  "https://family-events.up.railway.app",
  "http://localhost:5173",
  ..."http://127.0.0.1:5175",
];
export function resolveAllowedOrigin(origin: string | null): string | null {
  /* env ALLOWED_ORIGINS override */
}
export function buildCorsHeaders(
  allowedOrigin: string | null,
  methods = ["POST", "OPTIONS"],
): Record<string, string> {
  // sets Vary: Origin always; sets ACAO only when allowedOrigin is non-null
}
```

`_shared/service-role-handler.ts:6-13` (to change):

```ts
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};
const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };
```

These `corsHeaders` are used on the OPTIONS preflight (line 58) and on every JSON response (line 13/48).

`scrape-source/index.ts:13-49` — a full inline duplicate of `DEFAULT_ALLOWED_ORIGINS`,
`resolveAllowedOrigin`, and `buildCorsHeaders`.

`_shared/admin-handler.ts:66-69` — uses `http.ts#buildCorsHeaders` (defaults origin to `*`).

## Steps

### Step 1: service-role-handler → allowlist

Import from `cors.ts` and resolve per-request. `serveServiceRoleJson` currently builds a static
`corsHeaders`; make it per-request using the incoming `Origin`:

- In the `Deno.serve(async (req) => {...})` body, compute
  `const allowedOrigin = resolveAllowedOrigin(req.headers.get("Origin"));`
  `const corsHeaders = buildCorsHeaders(allowedOrigin, ["POST", "OPTIONS"]);`
- Use those headers for the OPTIONS response and for the `jsonResponse` helper (thread `corsHeaders`
  into `jsonResponse` instead of the module-level constant).

Note: these handlers serve service-role (server-to-server) callers that usually send **no** `Origin`;
`buildCorsHeaders(null, ...)` correctly omits ACAO for them — which is fine (no browser involved). Only
allowlisted browser origins get an ACAO. That is the intended behavior.

### Step 2: scrape-source → delete the duplicate, import the shared module

Remove `DEFAULT_ALLOWED_ORIGINS`, `resolveAllowedOrigin`, and `buildCorsHeaders` from
`scrape-source/index.ts:13-49` and import `resolveAllowedOrigin` + `buildCorsHeaders` from
`../_shared/cors.ts`. The call sites at `index.ts:58-59` keep working unchanged (same function names).
Keep the local `declare const EdgeRuntime ...` and `dueSourceLimit()` — those are not CORS.

### Step 3: admin-handler → allowlist

Change `admin-handler.ts` to resolve the origin via `cors.ts#resolveAllowedOrigin` and build headers via
`cors.ts#buildCorsHeaders` (with the methods the admin handler supports), instead of
`http.ts#buildCorsHeaders` which defaults to `*`. Preserve any allow-header customization the admin
handler currently passes.

### Step 4: Tests

Add/extend a vitest test (e.g. `_shared/cors.test.ts` if absent, or alongside an existing handler test):

- `resolveAllowedOrigin` returns the origin for an allowlisted value, `null` for a random origin, and
  honors `ALLOWED_ORIGINS` env override.
- `buildCorsHeaders(null)` omits `Access-Control-Allow-Origin` but sets `Vary: Origin`.
- `buildCorsHeaders("https://family-events.org")` sets ACAO to exactly that origin.

## Commands you will need

| Purpose              | Command                                                                                 | Expected                                                         |
| -------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Typecheck            | `pnpm run check`                                                                        | exit 0                                                           |
| Function tests       | `pnpm -C supabase/functions exec vitest run` and `deno test` (cwd `supabase/functions`) | pass                                                             |
| Confirm no stray `*` | `grep -rn '"Access-Control-Allow-Origin": "\*"' supabase/functions`                     | only matches remain in intentionally-public functions (see STOP) |

## Scope

**In scope:** `_shared/service-role-handler.ts`, `_shared/admin-handler.ts`, `scrape-source/index.ts`,
a CORS test file.
**Out of scope:** `share-og` and `sitemap` are intentionally public GET endpoints (OG crawlers, search
engines) — their `*` / permissive CORS is by design. Do NOT lock those down. `http.ts#buildCorsHeaders`
may still be used by those; leave it.

## Done criteria

- [ ] `service-role-handler.ts` no longer contains a hardcoded `"Access-Control-Allow-Origin": "*"`
- [ ] `scrape-source/index.ts` imports `resolveAllowedOrigin`/`buildCorsHeaders` from `_shared/cors.ts`
      and no longer declares its own copies
- [ ] `admin-handler.ts` resolves origin via `_shared/cors.ts`
- [ ] `pnpm run check` exits 0; function tests pass; new CORS tests pass
- [ ] `share-og`/`sitemap` unchanged
- [ ] `plans/README.md` row for 006 updated

## STOP conditions

- The allowlist in `cors.ts` is missing a production origin the app actually uses (check the deployed
  frontend domain) — report; an over-narrow allowlist breaks the browser app.
- A function under change is invoked from the browser with credentials and relies on `*` — report
  before tightening (you cannot use `*` with credentialed CORS anyway, so this would already be broken).

## Maintenance notes

- Reviewer: confirm no behavior change for server-to-server callers (they send no `Origin`, so ACAO is
  simply omitted — correct).
- Follow-up deferred: auditing every other function's CORS for the same pattern; this plan covers the
  shared handlers + scrape-source, which is where the duplication lived.
