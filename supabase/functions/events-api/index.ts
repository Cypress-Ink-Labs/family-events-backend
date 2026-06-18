import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";

// TODO: no rate limiting — do not announce this endpoint publicly until
// per-IP rate limiting is implemented (Upstash Redis or Cloudflare WAF rule).
// See supabase/docs/PUBLIC_API.md § Rate limiting.

// Public API v1 — GET /events
// Thin façade over public.search_events() with param validation + JSON envelope.
// Auth model: anonymous public GET (verify_jwt = false). Open CORS.
// See supabase/docs/PUBLIC_API.md for full design decisions.

// Cache: 60 s at CDN + stale-while-revalidate 30 s.
// Event data mutates (status flips, edits); keep TTL short so stale published
// events are not pinned at the edge for long.
const CACHE_CONTROL = "public, max-age=60, s-maxage=60, stale-while-revalidate=30";

// Public API caps limit at 100 (RPC allows 500; keep the public surface tighter).
const MAX_LIMIT = 100;
const DEFAULT_LIMIT = 20;

// Slug validation for tag params.
const SLUG_PATTERN = /^[a-z0-9-]{1,50}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// ── CORS ─────────────────────────────────────────────────────────────────────
// Open GET for all origins — this is a public read API for partner integrations.
// Differs from _shared/cors.ts allowlist (app-facing functions only).
// See PUBLIC_API.md § CORS.
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Apikey",
};

// ── Cursor encoding ───────────────────────────────────────────────────────────

type Cursor = { after_start: string; after_id: string };

function encodeCursor(afterStart: string, afterId: string): string {
  return btoa(JSON.stringify({ after_start: afterStart, after_id: afterId }));
}

export function decodeCursor(raw: string): Cursor | null {
  try {
    const decoded = JSON.parse(atob(raw));
    if (
      typeof decoded !== "object" ||
      decoded === null ||
      typeof decoded.after_start !== "string" ||
      typeof decoded.after_id !== "string" ||
      !UUID_PATTERN.test(decoded.after_id) ||
      !isFinite(new Date(decoded.after_start).getTime())
    ) {
      return null;
    }
    return { after_start: decoded.after_start, after_id: decoded.after_id };
  } catch {
    return null;
  }
}

// ── Param validation ──────────────────────────────────────────────────────────

export type ParsedParams = {
  cityId: string | null;
  dateFrom: string | null;
  dateTo: string | null;
  isFree: boolean | null;
  tags: string[] | null;
  keyword: string | null;
  limit: number;
  cursor: Cursor | null;
};

export type ParseError = { field: string; message: string };

export function parseParams(
  searchParams: URLSearchParams,
): { ok: true; params: ParsedParams } | { ok: false; error: ParseError } {
  // city_id
  const rawCityId = searchParams.get("city_id");
  if (rawCityId !== null && !UUID_PATTERN.test(rawCityId)) {
    return { ok: false, error: { field: "city_id", message: "must be a valid UUID" } };
  }
  const cityId = rawCityId ?? null;

  // date_from
  const rawDateFrom = searchParams.get("date_from");
  let dateFrom: string | null = null;
  if (rawDateFrom !== null) {
    const t = new Date(rawDateFrom).getTime();
    if (!isFinite(t)) {
      return {
        ok: false,
        error: { field: "date_from", message: "must be a valid ISO 8601 datetime" },
      };
    }
    dateFrom = new Date(rawDateFrom).toISOString();
  }

  // date_to
  const rawDateTo = searchParams.get("date_to");
  let dateTo: string | null = null;
  if (rawDateTo !== null) {
    const t = new Date(rawDateTo).getTime();
    if (!isFinite(t)) {
      return {
        ok: false,
        error: { field: "date_to", message: "must be a valid ISO 8601 datetime" },
      };
    }
    dateTo = new Date(rawDateTo).toISOString();
  }

  // is_free
  const rawIsFree = searchParams.get("is_free");
  let isFree: boolean | null = null;
  if (rawIsFree !== null) {
    if (rawIsFree !== "true" && rawIsFree !== "false") {
      return {
        ok: false,
        error: { field: "is_free", message: 'must be "true" or "false"' },
      };
    }
    isFree = rawIsFree === "true";
  }

  // tags (comma-separated slugs, max 10)
  const rawTags = searchParams.get("tags");
  let tags: string[] | null = null;
  if (rawTags !== null) {
    const parts = rawTags
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
    if (parts.length > 10) {
      return { ok: false, error: { field: "tags", message: "max 10 tags allowed" } };
    }
    for (const slug of parts) {
      if (!SLUG_PATTERN.test(slug)) {
        return {
          ok: false,
          error: { field: "tags", message: `invalid slug: "${slug}"` },
        };
      }
    }
    tags = parts.length > 0 ? parts : null;
  }

  // keyword (max 100 chars)
  const rawKeyword = searchParams.get("keyword");
  let keyword: string | null = null;
  if (rawKeyword !== null) {
    const trimmed = rawKeyword.trim();
    if (trimmed.length > 100) {
      return {
        ok: false,
        error: { field: "keyword", message: "max 100 characters" },
      };
    }
    keyword = trimmed.length > 0 ? trimmed : null;
  }

  // limit (1–100)
  const rawLimit = searchParams.get("limit");
  let limit = DEFAULT_LIMIT;
  if (rawLimit !== null) {
    const n = parseInt(rawLimit, 10);
    if (!isFinite(n) || n < 1 || n > MAX_LIMIT || String(n) !== rawLimit) {
      return {
        ok: false,
        error: { field: "limit", message: `must be an integer between 1 and ${MAX_LIMIT}` },
      };
    }
    limit = n;
  }

  // cursor (opaque base64)
  const rawCursor = searchParams.get("cursor");
  let cursor: Cursor | null = null;
  if (rawCursor !== null) {
    cursor = decodeCursor(rawCursor);
    if (cursor === null) {
      return { ok: false, error: { field: "cursor", message: "invalid or malformed cursor" } };
    }
  }

  return {
    ok: true,
    params: { cityId, dateFrom, dateTo, isFree, tags, keyword, limit, cursor },
  };
}

// ── Public projection ─────────────────────────────────────────────────────────
// search_events returns SETOF events (full row). We project only the public
// columns listed in PUBLIC_API.md to avoid leaking internal/LLM fields.
// See PUBLIC_API.md § Columns intentionally excluded.

type RawEventRow = Record<string, unknown>;

type PublicEvent = {
  id: string;
  title: string;
  description: string | null;
  start_datetime: string;
  end_datetime: string | null;
  timezone: string | null;
  venue_name: string | null;
  address: string | null;
  city_id: string | null;
  latitude: number | null;
  longitude: number | null;
  age_min: number | null;
  age_max: number | null;
  price: number | null;
  is_free: boolean;
  is_featured: boolean;
  is_outdoor: boolean | null;
  images: unknown[];
  source_url: string | null;
};

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
  };
}

// ── Handler ───────────────────────────────────────────────────────────────────

export async function handleEventsApi(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: CORS_HEADERS });
  }
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "method not allowed" }), {
      status: 405,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  const url = new URL(req.url);
  const parsed = parseParams(url.searchParams);
  if (!parsed.ok) {
    return new Response(
      JSON.stringify({
        error: `invalid parameter: ${parsed.error.field} — ${parsed.error.message}`,
      }),
      { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
    );
  }

  const { cityId, dateFrom, dateTo, isFree, tags, keyword, limit, cursor } = parsed.params;

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  if (!supabaseUrl || !anonKey) {
    return new Response(JSON.stringify({ error: "service unavailable" }), {
      status: 503,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

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
  });

  if (error) {
    return new Response(JSON.stringify({ error: "query failed" }), {
      status: 500,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  const rows = (data ?? []) as RawEventRow[];
  const hasMore = rows.length > limit;
  const pageRows = hasMore ? rows.slice(0, limit) : rows;
  const events = pageRows.map(projectEvent);

  let nextCursor: string | undefined;
  if (hasMore && pageRows.length > 0) {
    const last = pageRows[pageRows.length - 1];
    nextCursor = encodeCursor(last.start_datetime as string, last.id as string);
  }

  const envelope: Record<string, unknown> = { data: events };
  if (nextCursor !== undefined) {
    envelope.next_cursor = nextCursor;
  }

  return new Response(JSON.stringify(envelope), {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": CACHE_CONTROL,
    },
  });
}

if (import.meta.main) {
  Deno.serve(handleEventsApi);
}
