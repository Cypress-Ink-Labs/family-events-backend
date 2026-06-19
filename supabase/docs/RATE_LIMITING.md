# Rate Limiting — Design Spike for the public `events-api`

> Status: **Decision spike** (plan 029). This document picks an approach and
> specifies a build-ready design. **No production rate limiter is shipped by
> this plan** — implementation is a follow-up build plan. See the TODO at the
> top of `supabase/functions/events-api/index.ts` and the "Rate limiting"
> section of `supabase/docs/PUBLIC_API.md`.

## Problem

`GET /functions/v1/events-api` is an anonymous, open-CORS, `verify_jwt = false`
public read endpoint (see `config/deploy.config.json` → `noVerifyJwtFunctions`).
It is intentionally **undiscoverable** until per-IP rate limiting exists: an
un-throttled anonymous endpoint backed by `search_events` (a full-text +
filter query against Postgres) is a trivial amplification / cost vector. A
single abusive client can saturate the DB connection pool and degrade the whole
project, not just this function.

Target (from `PUBLIC_API.md`): **~100 req/min per IP, burst ~200**, on
`GET /events`.

Constraints specific to this deployment:

- **Stateless edge runtime.** Supabase Edge Functions run on Deno isolates that
  are recycled between invocations and scaled horizontally. Module-level state
  (the pattern `_shared/geocode.ts` uses for the Nominatim limiter) is per-isolate
  and does **not** coordinate across instances — confirmed by plan 011, which
  exists precisely because in-isolate counters undercount aggregate traffic.
  Any correct limiter therefore needs a **shared store**.
- **No built-in primitive.** Supabase Edge Functions expose no native rate-limit
  hook. The limit must be implemented in our code or at an infra layer in front.
- **Backend split.** The data plane is Supabase (Postgres + Edge Functions);
  some worker/cron orchestration runs on Railway, but the public `events-api`
  request path terminates at the Supabase edge — Railway is **not** in front of
  these requests, so it is not a viable enforcement point.

---

## Step 1 — Client-IP source on this platform

**Finding: the real client IP IS available to the edge function via the
`x-forwarded-for` request header.** Supabase Edge Functions sit behind the
Supabase API gateway (Kong) and Cloudflare; both append the originating client
IP to `x-forwarded-for`. No function in this repo reads it today
(`grep -rn "x-forwarded-for\|cf-connecting-ip\|forwarded\|x-real-ip" supabase/functions`
returns nothing), so this is greenfield.

Recommended extraction (most robust → least):

1. `cf-connecting-ip` — single, un-spoofable-by-client value **when the request
   actually transited Cloudflare**. Present on the Supabase-hosted edge; absent
   under `supabase functions serve` locally.
2. `x-forwarded-for` — a comma-separated chain `client, proxy1, proxy2, …`.
   Take the **left-most** entry as the client. This is the portable fallback and
   is always present on the hosted platform.
3. `x-real-ip` — single value some proxies set; last-resort fallback.

```ts
// _shared/client-ip.ts (build plan; sketch only)
export function clientIp(req: Request): string | null {
  const cf = req.headers.get("cf-connecting-ip")
  if (cf) return cf.trim()
  const xff = req.headers.get("x-forwarded-for")
  if (xff) {
    const first = xff.split(",")[0]?.trim()
    if (first) return first
  }
  return req.headers.get("x-real-ip")?.trim() ?? null
}
```

**Spoofing note.** `x-forwarded-for` is client-settable, but on the hosted
platform the gateway **appends** the observed peer IP, so the *right-most*
entry is trustworthy and the *left-most* is attacker-controlled. For a per-IP
fairness limiter (not a security boundary — RLS is the security boundary, see
`PUBLIC_API.md` § Auth model), keying on the left-most XFF entry is the standard
trade-off: a determined attacker can rotate the spoofed left-most value to evade
the bucket, but doing so does not grant data access and is mitigated by the
defense-in-depth notes below. `cf-connecting-ip`, when present, is **not**
client-spoofable and is preferred.

**Conclusion:** the client IP is reliably available, so the limiter does **not**
have to live at the Cloudflare/infra layer. The STOP condition ("real client IP
not available → limiter must be infra-only") does **not** trigger.

---

## Step 2 — Option comparison (this stack)

| Dimension | 1. Upstash Redis (sliding window) | 2. Postgres token-bucket (RPC) | 3. Cloudflare WAF / rate-limit rule |
|---|---|---|---|
| How it works here | Edge fn calls Upstash REST API per request (`@upstash/ratelimit`), keyed by IP | Edge fn calls a `SECURITY DEFINER` RPC that atomically debits a per-IP token bucket row | A rate-limit rule on the CF zone fronting the project; matches path + client IP, returns 429 before the request reaches the edge fn |
| Latency added / request | 1 extra network round-trip to Upstash (~5–30 ms region-dependent) | 1 extra DB round-trip on the **existing** pooled connection (~1–5 ms; the fn already round-trips to Postgres for `search_events`, so this can piggyback) | **Zero** added to the edge fn — enforced upstream; blocked requests never hit us |
| New infra | New external service (Upstash account) | **None** — reuses the Postgres we already have | Requires the project to be fronted by a **Cloudflare zone we control** (managed CF, not Supabase's own CF) |
| New secrets | `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN` (must be provisioned + rotated) | **None** | None in this repo (config lives in the CF dashboard / Terraform) |
| Failure mode under store outage | Upstash down → fn must choose fail-open (recommended) or fail-closed; an extra dependency that can itself fail | Postgres down → `search_events` already fails (500); the limiter shares fate, so a limiter outage implies the endpoint is already down → naturally fail-open with no *new* single point of failure | CF outage takes the whole site down regardless; limiter adds no new failure surface |
| Multi-region correctness | Strong — Redis is the single source of truth; sliding window is precise | Strong — Postgres is the single source of truth; advisory-lock serializes the debit | Per-CF-PoP counters are approximate across PoPs, but adequate for coarse abuse limits |
| Operational burden | Medium — extra dashboard, billing, key rotation, an SLA to track | **Low** — one migration + rollback; observable via existing DB tooling; no new vendor | Low day-to-day, but **out of this repo** — needs infra ownership + a CF account fronting the project |
| Repo precedent | none | **Direct** — plan 011 established the advisory-lock + `private` table + `public`/`private` RPC pattern for exactly this "coordinate across stateless isolates via Postgres" problem | none |

Grounding against repo reality:

- Plan 011 already solved "stateless isolates need a shared coordination point"
  with a Postgres advisory-lock RPC. A per-IP token bucket is the same shape.
- The degrade-on-failure precedent (plan 011, option 3 / the Nominatim 429
  fallback) argues strongly for **fail-open**: a public read API must not go
  dark because its *limiter* store hiccuped.
- The function already opens a Supabase client and round-trips to Postgres for
  every request, so option 2 adds one cheap call on a connection that already
  exists — no new connection, no new vendor, no new secret.

### Recommendation: **Option 2 — Postgres token-bucket RPC**

Rationale:

1. **Zero new infra and zero new secrets.** Everything needed already exists
   (Postgres + the function's Supabase client). Upstash adds a paid external
   dependency and two rotatable secrets for a v1 with no partners yet.
2. **Naturally fail-open with no *new* single point of failure.** If Postgres is
   down the endpoint is already returning 500 from `search_events`; the limiter
   shares that fate rather than introducing a second store that can fail
   independently (Upstash) and force a fail-open-vs-fail-closed dilemma.
3. **Established repo pattern.** Plan 011's advisory-lock RPC is a working
   template for coordinating across stateless isolates via Postgres.
4. **Low operational burden.** One append-only migration + paired rollback,
   observable with the DB tooling already in use.

**When to revisit:** if request volume grows enough that one extra DB call per
request becomes a measurable pool-contention cost, **and** the project is fronted
by a Cloudflare zone we control, move enforcement to **option 3 (Cloudflare
rate-limit rule)** — it adds zero latency and blocks abuse before it reaches the
DB. Treat option 3 as the scaling endgame; it is an **infra-layer decision
outside this repo** and is explicitly *not* part of the follow-up build plan.
Option 1 (Upstash) is only worth it if we later need precise sliding-window
semantics or per-partner quotas that outgrow Postgres — at which point the
`api_keys` work in `PUBLIC_API.md` open question #2 is the better vehicle.

---

## Step 3 — Build-ready design (Option 2)

### 3.1 Limit and window

- **100 requests / 60 s per IP**, with a **burst of 200** (bucket capacity 200,
  refill 100 tokens/min ≈ 1.667 tokens/s). This matches the `PUBLIC_API.md`
  target. One request costs **1 token**.
- Capacity > steady rate gives partners headroom for short bursts (e.g. a page
  that fans out a few parallel requests) while bounding sustained abuse.
- Keyed by **client IP** (Step 1). Requests with **no resolvable IP** (only
  local dev / misconfigured proxy) are **not** limited — fail-open.

### 3.2 Where the check sits in `events-api`

In `handleEventsApi`, **after** method + param validation but **before** the
`search_events` RPC call (no point spending a DB query on a request we will
reject; and rejecting malformed requests at 400 first avoids spending tokens on
obviously-bad input — debit only well-formed GETs):

```
OPTIONS → 200 (no debit)
non-GET → 405 (no debit)
parse params → 400 on failure (no debit)
── rate-limit gate (NEW) ──
  ip = clientIp(req); if null → skip (fail-open)
  { allowed, remaining, reset_at, retry_after } = await rateLimit(supabase, ip)
  if (!allowed) → 429 + headers (below); return
  on RPC error → log + ALLOW (fail-open); continue
search_events RPC → project → 200 (+ X-RateLimit-* headers)
```

The gate needs the Supabase client; the function already constructs one
(`createClient(supabaseUrl, anonKey, …)`). The limiter RPC is `SECURITY DEFINER`
so the **anon** client may call it (EXECUTE granted to `anon`), but it writes
only to a `private` table the anon role cannot touch directly.

### 3.3 Data model + RPC

A `private` schema table (not anon-readable) plus a `public` wrapper RPC that
performs an atomic debit under an advisory lock — mirroring
`supabase/migrations/20260601029000_*` / plan 011.

```sql
-- private state: one row per active IP bucket
CREATE TABLE private.events_api_rate_buckets (
  ip          inet        PRIMARY KEY,
  tokens      real        NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- atomic debit; returns allow/deny + headers data
CREATE OR REPLACE FUNCTION public.events_api_rate_limit(
  p_ip           inet,
  p_capacity     real DEFAULT 200,   -- burst
  p_refill_per_s real DEFAULT 1.667, -- 100/min
  p_cost         real DEFAULT 1
)
RETURNS TABLE (allowed boolean, remaining int, reset_seconds int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_now    timestamptz := clock_timestamp();
  v_tokens real;
  v_last   timestamptz;
BEGIN
  -- serialize the read-modify-write for this IP across isolates/instances.
  -- hashtextextended keeps the lock key per-IP so distinct IPs never contend.
  PERFORM pg_advisory_xact_lock(hashtextextended(host(p_ip), 0));

  SELECT tokens, updated_at INTO v_tokens, v_last
  FROM private.events_api_rate_buckets WHERE ip = p_ip;

  IF NOT FOUND THEN
    v_tokens := p_capacity;
    v_last   := v_now;
  ELSE
    -- refill since last seen, clamped to capacity
    v_tokens := LEAST(
      p_capacity,
      v_tokens + EXTRACT(EPOCH FROM (v_now - v_last)) * p_refill_per_s
    );
  END IF;

  IF v_tokens >= p_cost THEN
    v_tokens := v_tokens - p_cost;
    allowed  := true;
  ELSE
    allowed  := false;
  END IF;

  INSERT INTO private.events_api_rate_buckets (ip, tokens, updated_at)
  VALUES (p_ip, v_tokens, v_now)
  ON CONFLICT (ip) DO UPDATE SET tokens = EXCLUDED.tokens, updated_at = EXCLUDED.updated_at;

  remaining     := GREATEST(0, floor(v_tokens))::int;
  -- seconds until at least one token (>= p_cost) is available again
  reset_seconds := CASE
    WHEN allowed THEN 0
    ELSE ceil((p_cost - v_tokens) / NULLIF(p_refill_per_s, 0))::int
  END;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.events_api_rate_limit(inet, real, real, real)
  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.events_api_rate_limit(inet, real, real, real)
  TO anon, authenticated, service_role;
```

Notes:
- `pg_advisory_xact_lock` is transaction-scoped → auto-released; per-IP key so
  distinct IPs never serialize against each other.
- All mutation is in one statement after the lock; the function does no
  network/sleep inside the lock (contrast plan 011, where the *sleep* must be
  outside the lock).
- The `private` table is unreachable by `anon`/`authenticated` directly; only
  the `SECURITY DEFINER` RPC may touch it.

**Bucket-row growth / GC.** Rows accumulate one per distinct IP. A scheduled
cleanup deletes idle buckets (a fully-refilled bucket is indistinguishable from
absent):

```sql
DELETE FROM private.events_api_rate_buckets
WHERE updated_at < now() - interval '1 hour';
```

Run it via the existing cron/`db-maintenance` path (the build plan wires the
schedule; this spike only specifies it). This keeps the table bounded.

### 3.4 Response on limit (429)

```
HTTP/1.1 429 Too Many Requests
Content-Type: application/json; charset=utf-8
Retry-After: <reset_seconds>
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: <unix-epoch-seconds when a token frees up>
Access-Control-Allow-Origin: *   (CORS_HEADERS as on every response)

{ "error": "rate limit exceeded" }
```

On **allowed** responses, attach the informational headers too:
`X-RateLimit-Limit: 100`, `X-RateLimit-Remaining: <remaining>`,
`X-RateLimit-Reset: <epoch>`. `Retry-After` is sent only on 429.

`X-RateLimit-Limit` reflects the **sustained** rate (100/min); the burst
capacity (200) is intentionally not advertised as the headline number to keep
client expectations conservative.

### 3.5 Fail-open policy (reviewer's flagged risk)

**The limiter fails OPEN.** If `clientIp()` returns null, or the
`events_api_rate_limit` RPC errors/times out, the request is **allowed** and a
warning is logged (via `_shared/logger.ts`). A public read API must not go dark
because its limiter store hiccuped. Because the limiter and `search_events`
share the same Postgres, a limiter outage means the endpoint is already failing
anyway — fail-open adds no extra exposure window. Document this explicitly so a
future change does not silently flip it to fail-closed.

Defense-in-depth that does not depend on the limiter staying up: the CDN cache
(`Cache-Control: s-maxage=60`) already absorbs repeated identical queries at the
edge, and RLS + published-only projection bound what any volume of requests can
read.

### 3.6 Caching interaction

The limiter check must run on the function **even for cache-eligible requests**
that miss the CDN. Cache *hits* never reach the function, so they are
effectively un-limited — which is fine: a cache hit costs us nothing. The
limiter only protects the **origin** (DB) path. Do not add per-request
`Vary`/`no-store` for rate-limit headers; let cacheable 200s stay cacheable
(the `X-RateLimit-*` values on a cached response will be stale, which is
acceptable for informational headers).

### 3.7 Env / secrets

**None.** No new environment variables or secrets. The function reuses its
existing `SUPABASE_URL` + `SUPABASE_ANON_KEY`. (This is the headline advantage
over Upstash.)

### 3.8 Test plan (for the build plan)

- **Unit (Deno, no DB), via an injectable seam** — pass the limiter as a
  `rateLimit: (ip) => Promise<Decision>` callback into `handleEventsApi` (same
  testability pattern plan 011 uses for `reserveSlot`):
  - allowed decision → 200 with `X-RateLimit-*` headers present.
  - denied decision → 429 with `Retry-After` + `X-RateLimit-Remaining: 0`.
  - `clientIp()` returns null (no headers) → allowed, limiter **not** called
    (fail-open).
  - limiter callback throws → allowed, warning logged (fail-open).
  - OPTIONS / non-GET / 400-invalid-params → limiter **not** called (no debit).
  - `clientIp()` extraction: `cf-connecting-ip` wins; else left-most
    `x-forwarded-for`; else `x-real-ip`; else null.
- **DB test (`supabase/tests/`)** — token-bucket math + concurrency:
  - N+1th request within the window for one IP → `allowed = false`.
  - tokens refill after `reset_seconds` → next request allowed.
  - two concurrent calls for the same IP do not double-spend (advisory lock).
  - distinct IPs are independent.
  - `reset_seconds` is monotonic and > 0 only when denied.
- **Migration guards** — new migration is timestamp-greater than the current max
  and has a paired `_down.sql` under `supabase/rollbacks/`; `pnpm run
  workspace:test` (rollback-pairing guard) passes. Regenerate types
  (`pnpm run db:types`) so the new RPC appears in `database.types.ts`.

### 3.9 Open questions for the build plan

1. **`inet` vs `text` key.** `inet` is correct and indexes well; confirm the
   edge passes a parseable value and the RPC tolerates a malformed IP (treat
   parse failure as null → fail-open, do not 500).
2. **IPv6 granularity.** Per-/128 (single address) lets an attacker with a /64
   rotate freely. Consider keying IPv6 on the /64 prefix. Decide at build time;
   /128 is the simpler v1.
3. **Per-endpoint vs per-function limits.** v1 has one route; when
   `GET /events/{id}` etc. land (PUBLIC_API.md), decide whether they share one
   bucket or get separate cost weights (heavier `events_enriched_v2` could cost
   more tokens).
4. **GC scheduling owner.** Wire the idle-bucket cleanup into the existing cron
   (`db-maintenance` / `admin-run-cron`) — confirm which and add the schedule in
   the build plan, not here.
5. **Trust boundary for XFF.** Confirm on the hosted platform whether
   `cf-connecting-ip` is always present (then prefer it unconditionally) or
   whether some paths only set `x-forwarded-for`; harden the left-most-XFF
   choice accordingly.
6. **Scaling exit to Cloudflare.** Define the volume threshold / signal at which
   we move enforcement to a CF rate-limit rule (option 3) and retire the DB
   limiter — an infra decision, tracked separately from the edge build plan.

---

## STOP-condition check (recorded)

- Real client IP **is** reliably available (Step 1) → the "limiter must be
  infra-only" STOP condition does **not** trigger.
- This spike ships **no** enabled limiter and provisions **no** paid infra → the
  "would require enabling a live limiter / paid infra" STOP condition does
  **not** trigger. The optional inert scaffold (plan Step 4) is intentionally
  **skipped**: any migration here would ship a `private` table + RPC that, while
  unused, still alters the live schema and would need GC wiring to be safe — not
  "zero-risk." The build plan ships it together with the enforcement code and
  the GC schedule, which is the correct, reviewable unit.
