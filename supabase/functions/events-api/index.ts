import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "@supabase/supabase-js"
import { buildPublicCorsHeaders } from "../_shared/cors.ts"

// TODO: no rate limiting — do not announce this endpoint publicly until
// per-IP rate limiting is implemented. Approach chosen: Postgres token-bucket
// RPC (no new infra/secrets, fail-open). Build-ready design in
// supabase/docs/RATE_LIMITING.md; gap also noted in PUBLIC_API.md § Rate limiting.

// Public API v1 — GET /events
// Thin façade over public.search_events() with param validation + JSON envelope.
// Auth model: anonymous public GET (verify_jwt = false). Open CORS.
// See supabase/docs/PUBLIC_API.md for full design decisions.

// Cache: 60 s at CDN + stale-while-revalidate 30 s.
// Event data mutates (status flips, edits); keep TTL short so stale published
// events are not pinned at the edge for long.
const CACHE_CONTROL = "public, max-age=60, s-maxage=60, stale-while-revalidate=30"

// Public API caps limit at 100 (RPC allows 500; keep the public surface tighter).
const MAX_LIMIT = 100
const DEFAULT_LIMIT = 20

// Slug validation for tag params.
const SLUG_PATTERN = /^[a-z0-9-]{1,50}$/
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

// ── CORS ─────────────────────────────────────────────────────────────────────
// Open GET for all origins — this is a public read API for partner integrations.
// Differs from _shared/cors.ts allowlist (app-facing functions only).
// Allow-Headers is intentionally tighter than the shared default (no
// Authorization/X-Client-Info) — this surface only needs Content-Type + Apikey.
// See PUBLIC_API.md § CORS.
const CORS_HEADERS = buildPublicCorsHeaders(["GET", "OPTIONS"], ["Content-Type", "Apikey"])

// ── Cursor encoding ───────────────────────────────────────────────────────────

type Cursor = { after_start: string; after_id: string }

function encodeCursor(afterStart: string, afterId: string): string {
  return btoa(JSON.stringify({ after_start: afterStart, after_id: afterId }))
}

export function decodeCursor(raw: string): Cursor | null {
  try {
    const decoded = JSON.parse(atob(raw))
    if (
      typeof decoded !== "object" ||
      decoded === null ||
      typeof decoded.after_start !== "string" ||
      typeof decoded.after_id !== "string" ||
      !UUID_PATTERN.test(decoded.after_id) ||
      !isFinite(new Date(decoded.after_start).getTime())
    ) {
      return null
    }
    return { after_start: decoded.after_start, after_id: decoded.after_id }
  } catch {
    return null
  }
}

// ── Param validation ──────────────────────────────────────────────────────────

export type ParsedParams = {
  cityId: string | null
  dateFrom: string | null
  dateTo: string | null
  isFree: boolean | null
  tags: string[] | null
  keyword: string | null
  limit: number
  cursor: Cursor | null
}

export type ParseError = { field: string; message: string }

export function parseParams(
  searchParams: URLSearchParams
): { ok: true; params: ParsedParams } | { ok: false; error: ParseError } {
  // city_id
  const rawCityId = searchParams.get("city_id")
  if (rawCityId !== null && !UUID_PATTERN.test(rawCityId)) {
    return { ok: false, error: { field: "city_id", message: "must be a valid UUID" } }
  }
  const cityId = rawCityId ?? null

  // date_from
  const rawDateFrom = searchParams.get("date_from")
  let dateFrom: string | null = null
  if (rawDateFrom !== null) {
    const t = new Date(rawDateFrom).getTime()
    if (!isFinite(t)) {
      return {
        ok: false,
        error: { field: "date_from", message: "must be a valid ISO 8601 datetime" },
      }
    }
    dateFrom = new Date(rawDateFrom).toISOString()
  }

  // date_to
  const rawDateTo = searchParams.get("date_to")
  let dateTo: string | null = null
  if (rawDateTo !== null) {
    const t = new Date(rawDateTo).getTime()
    if (!isFinite(t)) {
      return {
        ok: false,
        error: { field: "date_to", message: "must be a valid ISO 8601 datetime" },
      }
    }
    dateTo = new Date(rawDateTo).toISOString()
  }

  // is_free
  const rawIsFree = searchParams.get("is_free")
  let isFree: boolean | null = null
  if (rawIsFree !== null) {
    if (rawIsFree !== "true" && rawIsFree !== "false") {
      return {
        ok: false,
        error: { field: "is_free", message: 'must be "true" or "false"' },
      }
    }
    isFree = rawIsFree === "true"
  }

  // tags (comma-separated slugs, max 10)
  const rawTags = searchParams.get("tags")
  let tags: string[] | null = null
  if (rawTags !== null) {
    const parts = rawTags
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
    if (parts.length > 10) {
      return { ok: false, error: { field: "tags", message: "max 10 tags allowed" } }
    }
    for (const slug of parts) {
      if (!SLUG_PATTERN.test(slug)) {
        return {
          ok: false,
          error: { field: "tags", message: `invalid slug: "${slug}"` },
        }
      }
    }
    tags = parts.length > 0 ? parts : null
  }

  // keyword (max 100 chars)
  const rawKeyword = searchParams.get("keyword")
  let keyword: string | null = null
  if (rawKeyword !== null) {
    const trimmed = rawKeyword.trim()
    if (trimmed.length > 100) {
      return {
        ok: false,
        error: { field: "keyword", message: "max 100 characters" },
      }
    }
    keyword = trimmed.length > 0 ? trimmed : null
  }

  // limit (1–100)
  const rawLimit = searchParams.get("limit")
  let limit = DEFAULT_LIMIT
  if (rawLimit !== null) {
    const n = parseInt(rawLimit, 10)
    if (!isFinite(n) || n < 1 || n > MAX_LIMIT || String(n) !== rawLimit) {
      return {
        ok: false,
        error: { field: "limit", message: `must be an integer between 1 and ${MAX_LIMIT}` },
      }
    }
    limit = n
  }

  // cursor (opaque base64)
  const rawCursor = searchParams.get("cursor")
  let cursor: Cursor | null = null
  if (rawCursor !== null) {
    cursor = decodeCursor(rawCursor)
    if (cursor === null) {
      return { ok: false, error: { field: "cursor", message: "invalid or malformed cursor" } }
    }
  }

  return {
    ok: true,
    params: { cityId, dateFrom, dateTo, isFree, tags, keyword, limit, cursor },
  }
}

// ── Routing ─────────────────────────────────────────────────────────────────
// Supabase serves this function at /functions/v1/events-api. Sub-paths arrive as
// /functions/v1/events-api/<segment>. We route off the segment that follows the
// function name (mirrors share-og's pathname parsing). Only the collection root
// and a single-event id are implemented here; /<id>/similar and /cities are
// specified (PUBLIC_API.md) but not yet built — they fall through to 404.

export type Route = { kind: "list" } | { kind: "event"; id: string } | { kind: "unknown" }

export function parseRoute(pathname: string): Route {
  const parts = pathname.split("/").filter((p) => p.length > 0)
  const idx = parts.findIndex((p) => p === "events-api")
  // Tail = path segments after the function name. Empty tail → list collection.
  const tail = idx >= 0 ? parts.slice(idx + 1) : parts
  if (tail.length === 0) {
    return { kind: "list" }
  }
  if (tail.length === 1) {
    const seg = decodeURIComponent(tail[0])
    // A bare single segment is a single-event lookup ONLY when it is a UUID.
    // Non-UUID single segments (e.g. "cities") are reserved for future routes
    // and must not be treated as an event id.
    if (UUID_PATTERN.test(seg)) {
      return { kind: "event", id: seg }
    }
    return { kind: "unknown" }
  }
  // Multi-segment tails (e.g. <id>/similar) are not built yet.
  return { kind: "unknown" }
}

// ── Public projection ─────────────────────────────────────────────────────────
// search_events returns SETOF events (full row). We project only the public
// columns listed in PUBLIC_API.md to avoid leaking internal/LLM fields.
// See PUBLIC_API.md § Columns intentionally excluded.

type RawEventRow = Record<string, unknown>

type PublicEvent = {
  id: string
  title: string
  description: string | null
  start_datetime: string
  end_datetime: string | null
  timezone: string | null
  venue_name: string | null
  address: string | null
  city_id: string | null
  latitude: number | null
  longitude: number | null
  age_min: number | null
  age_max: number | null
  price: number | null
  is_free: boolean
  is_featured: boolean
  is_outdoor: boolean | null
  images: unknown[]
  source_url: string | null
}

function projectEvent(row: RawEventRow): PublicEvent {
  return {
    id: row.id as string,
    title: row.title as string,
    description: (row.description as string | null) ?? null,
    start_datetime: row.start_datetime as string,
    end_datetime: (row.end_datetime as string | null) ?? null,
    timezone: (row.timezone as string | null) ?? null,
    venue_name: (row.venue_name as string | null) ?? null,
    address: (row.address as string | null) ?? null,
    city_id: (row.city_id as string | null) ?? null,
    latitude: (row.latitude as number | null) ?? null,
    longitude: (row.longitude as number | null) ?? null,
    age_min: (row.age_min as number | null) ?? null,
    age_max: (row.age_max as number | null) ?? null,
    price: (row.price as number | null) ?? null,
    is_free: Boolean(row.is_free),
    is_featured: Boolean(row.is_featured),
    is_outdoor: (row.is_outdoor as boolean | null) ?? null,
    images: Array.isArray(row.images) ? (row.images as unknown[]) : [],
    source_url: (row.source_url as string | null) ?? null,
  }
}

// ── Response helpers ──────────────────────────────────────────────────────────

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  })
}

function getAnonClient(): SupabaseClient | null {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? ""
  if (!supabaseUrl || !anonKey) {
    return null
  }
  // Anon key on purpose: RLS ("Anon can read published events") is the published-only
  // boundary for both endpoints. Never swap in the service-role key here — it would
  // bypass RLS and could leak draft/unpublished rows. See PUBLIC_API.md § Surface safety.
  return createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

// ── List handler (GET /events) ──────────────────────────────────────────────────

async function handleList(req: Request, supabase: SupabaseClient): Promise<Response> {
  const url = new URL(req.url)
  const parsed = parseParams(url.searchParams)
  if (!parsed.ok) {
    return jsonError(400, `invalid parameter: ${parsed.error.field} — ${parsed.error.message}`)
  }

  const { cityId, dateFrom, dateTo, isFree, tags, keyword, limit, cursor } = parsed.params

  const { data, error } = await supabase.rpc("search_events", {
    p_city_id: cityId ?? undefined,
    p_date_from: dateFrom ?? undefined,
    p_date_to: dateTo ?? undefined,
    p_is_free: isFree ?? undefined,
    p_tag_slugs: tags ?? undefined,
    p_keyword: keyword ?? undefined,
    p_limit: limit + 1, // fetch one extra to detect if there's a next page
    p_status: "published",
    p_after_start_datetime: cursor?.after_start ?? undefined,
    p_after_id: cursor?.after_id ?? undefined,
  })

  if (error) {
    return jsonError(500, "query failed")
  }

  const rows = (data ?? []) as RawEventRow[]
  const hasMore = rows.length > limit
  const pageRows = hasMore ? rows.slice(0, limit) : rows
  const events = pageRows.map(projectEvent)

  let nextCursor: string | undefined
  if (hasMore && pageRows.length > 0) {
    const last = pageRows[pageRows.length - 1]
    nextCursor = encodeCursor(last.start_datetime as string, last.id as string)
  }

  const envelope: Record<string, unknown> = { data: events }
  if (nextCursor !== undefined) {
    envelope.next_cursor = nextCursor
  }

  return new Response(JSON.stringify(envelope), {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": CACHE_CONTROL,
    },
  })
}

// ── Single-event handler (GET /events/{id}) ───────────────────────────────────
// Reads events_enriched_v2 filtered by p_event_ids = ARRAY[id]. The RPC is
// SECURITY INVOKER, so the anon RLS policy (published-only) does the gating: an
// unpublished or missing id resolves to zero rows → 404. See PUBLIC_API.md.

async function handleGetEvent(id: string, supabase: SupabaseClient): Promise<Response> {
  const { data, error } = await supabase.rpc("events_enriched_v2", {
    p_event_ids: [id],
  })

  if (error) {
    return jsonError(500, "query failed")
  }

  const rows = (data ?? []) as RawEventRow[]
  if (rows.length === 0) {
    // Not found OR not published (RLS-filtered). No cache header so a freshly
    // published event is not pinned as "missing" at the edge.
    return jsonError(404, "event not found")
  }

  return new Response(JSON.stringify({ data: projectEvent(rows[0]) }), {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": CACHE_CONTROL,
    },
  })
}

// ── Handler ───────────────────────────────────────────────────────────────────

export async function handleEventsApi(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: CORS_HEADERS })
  }
  if (req.method !== "GET") {
    return jsonError(405, "method not allowed")
  }

  const url = new URL(req.url)
  const route = parseRoute(url.pathname)
  if (route.kind === "unknown") {
    return jsonError(404, "not found")
  }

  const supabase = getAnonClient()
  if (supabase === null) {
    return jsonError(503, "service unavailable")
  }

  if (route.kind === "event") {
    return await handleGetEvent(route.id, supabase)
  }
  return await handleList(req, supabase)
}

if (import.meta.main) {
  Deno.serve(handleEventsApi)
}
