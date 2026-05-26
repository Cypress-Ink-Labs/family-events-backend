import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { escapeHtml } from "../_shared/html.ts";
import { buildCorsHeaders } from "../_shared/http.ts";
import { validateExternalUrl } from "../_shared/url-validation.ts";

const corsHeaders = buildCorsHeaders({ methods: ["GET", "OPTIONS"] });

// CDN cache TTL is short on purpose: event data mutates (status flips,
// description edits, cancellation), and a long s-maxage keeps the stale
// preview pinned at the edge. 5 min is enough to absorb crawler spikes
// without holding a deleted/unpublished event visible for hours.
const CACHE_CONTROL_SUCCESS =
  "public, max-age=300, s-maxage=300, stale-while-revalidate=60";
const CACHE_CONTROL_FALLBACK = "public, max-age=60, s-maxage=60";
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const OG_IMAGE_WIDTH = "1200";
const OG_IMAGE_HEIGHT = "630";
const MAX_OG_DESCRIPTION_LENGTH = 200;

const FALLBACK_TITLE = "Family Events - this event is no longer available";
const FALLBACK_DESCRIPTION =
  "This event is no longer available. Open Family Events to find current plans for your family.";

type PublicEventRow = {
  id: string;
  title: string;
  description: string | null;
  venue_name: string | null;
  start_datetime: string;
  images: unknown;
};

// U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) are valid in JSON but
// illegal as raw characters inside JS string literals (engines treat them as
// line terminators), breaking the inline <script>. Escape them defensively.
// Constructed via String.fromCharCode so this source file itself stays free of
// the raw separators (which would confuse the TS parser as line terminators).
const JS_LINE_TERMINATOR_REGEX = new RegExp(
  `[${String.fromCharCode(0x2028)}${String.fromCharCode(0x2029)}]`,
  "g",
);

function serializeForInlineScript(value: unknown): string {
  return JSON.stringify(value ?? "")
    .replaceAll("</", "<\\/")
    .replace(
      JS_LINE_TERMINATOR_REGEX,
      (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`,
    );
}

export function truncateOgDescription(input: string | null): string {
  const normalized = (input ?? "").trim();
  if (!normalized) {
    return FALLBACK_DESCRIPTION;
  }
  if (normalized.length <= MAX_OG_DESCRIPTION_LENGTH) {
    return normalized;
  }
  return `${normalized.slice(0, MAX_OG_DESCRIPTION_LENGTH - 3).trimEnd()}...`;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((entry): entry is string => typeof entry === "string");
}

function imageUrlLooksLikeFile(url: string): boolean {
  return /\.(png|jpe?g|webp|gif|avif)(?:$|[?#])/i.test(url);
}

export function pickOgImage(images: unknown, origin: string): string {
  for (const candidate of asStringArray(images)) {
    const validation = validateExternalUrl(candidate);
    if (!validation.ok) {
      continue;
    }

    let parsed: URL;
    try {
      parsed = new URL(candidate);
    } catch {
      continue;
    }

    if (parsed.protocol !== "https:") {
      continue;
    }
    if (!imageUrlLooksLikeFile(parsed.pathname + parsed.search + parsed.hash)) {
      continue;
    }
    return parsed.toString();
  }

  return `${origin}/og-fallback.png`;
}

export function extractEventIdFromRequest(url: URL): string | null {
  const queryEventId = url.searchParams.get("eventId") ??
    url.searchParams.get("event_id");
  const candidate = queryEventId ??
    (() => {
      const pathParts = url.pathname.split("/").filter(Boolean);
      const idx = pathParts.findIndex((part) => part === "share-og");
      if (idx >= 0 && pathParts[idx + 1]) {
        return decodeURIComponent(pathParts[idx + 1]);
      }
      return null;
    })();

  if (!candidate) return null;
  // Reject non-UUIDs before hitting the DB. Postgres returns 22P02 for non-UUID
  // input to a uuid column, which works correctly but pollutes Sentry breadcrumbs.
  return UUID_PATTERN.test(candidate) ? candidate : null;
}

function renderHtml(params: {
  title: string;
  description: string;
  ogImageUrl: string;
  ogUrl: string;
  noIndex: boolean;
  eventId: string | null;
  venueName: string | null;
  startDatetime: string | null;
}): string {
  const escapedTitle = escapeHtml(params.title);
  const escapedDescription = escapeHtml(params.description);
  const escapedImage = escapeHtml(params.ogImageUrl);
  const escapedUrl = escapeHtml(params.ogUrl);
  const escapedVenue = escapeHtml(params.venueName ?? "Family Events");
  const escapedStart = escapeHtml(params.startDatetime ?? "");
  const serializedEventId = serializeForInlineScript(params.eventId);

  // ASCII flow (required by EXECUTE.md decision notes):
  //
  //   request /share/:id
  //        |
  //        v
  //   read public_events (anon key, RLS)
  //     |              |
  //     |found         |missing/unpublished/invalid
  //     v              v
  //  OG meta + cache   generic OG + noindex
  //        \            /
  //         \          /
  //          v        v
  //        return SSR HTML shell
  //
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${escapedTitle}</title>
    <meta property="og:title" content="${escapedTitle}" />
    <meta property="og:description" content="${escapedDescription}" />
    <meta property="og:image" content="${escapedImage}" />
    <meta property="og:image:width" content="${OG_IMAGE_WIDTH}" />
    <meta property="og:image:height" content="${OG_IMAGE_HEIGHT}" />
    <meta property="og:url" content="${escapedUrl}" />
    <meta property="og:type" content="website" />
    <meta name="twitter:card" content="summary_large_image" />
    ${params.noIndex ? '<meta name="robots" content="noindex" />' : ""}
    <style>
      body {
        margin: 0;
        font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #0b1020;
        color: #f8fafc;
      }
      .shell {
        min-height: 100vh;
        display: grid;
        place-items: center;
        padding: 24px;
      }
      .card {
        width: min(720px, 100%);
        border: 1px solid rgba(148, 163, 184, 0.25);
        border-radius: 16px;
        background: rgba(15, 23, 42, 0.82);
        padding: 20px;
      }
      .meta {
        font-size: 14px;
        color: #94a3b8;
        margin: 0 0 8px;
      }
      .title {
        margin: 0 0 10px;
        font-size: 28px;
        line-height: 1.2;
      }
      .desc {
        margin: 0;
        color: #cbd5e1;
        line-height: 1.5;
      }
      .cta {
        display: inline-block;
        margin-top: 16px;
        color: #0f172a;
        background: #f59e0b;
        border-radius: 10px;
        text-decoration: none;
        font-weight: 700;
        padding: 10px 14px;
      }
    </style>
  </head>
  <body>
    <div id="root">
      <main class="shell">
        <article class="card">
          <p class="meta">${escapedVenue}${
    escapedStart ? ` · ${escapedStart}` : ""
  }</p>
          <h1 class="title">${escapedTitle}</h1>
          <p class="desc">${escapedDescription}</p>
          <a class="cta" href="/sign-up">Open in Family Events</a>
        </article>
      </main>
    </div>
    <script>
      window.__PUBLIC_SHARE_EVENT_ID__ = ${serializedEventId};
    </script>
  </body>
</html>`;
}

function responseHeaders(cacheControl: string): HeadersInit {
  return {
    ...corsHeaders,
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": cacheControl,
  };
}

export async function handleShareOg(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  const requestUrl = new URL(req.url);
  const eventId = extractEventIdFromRequest(requestUrl);
  const ogUrl = eventId
    ? `${requestUrl.origin}/share/${encodeURIComponent(eventId)}`
    : `${requestUrl.origin}/share`;

  if (!eventId) {
    return new Response(
      renderHtml({
        title: FALLBACK_TITLE,
        description: FALLBACK_DESCRIPTION,
        ogImageUrl: `${requestUrl.origin}/og-fallback.png`,
        ogUrl,
        noIndex: true,
        eventId: null,
        venueName: null,
        startDatetime: null,
      }),
      { status: 200, headers: responseHeaders(CACHE_CONTROL_FALLBACK) },
    );
  }

  if (!supabaseUrl || !anonKey) {
    return new Response(
      renderHtml({
        title: FALLBACK_TITLE,
        description: FALLBACK_DESCRIPTION,
        ogImageUrl: `${requestUrl.origin}/og-fallback.png`,
        ogUrl,
        noIndex: true,
        eventId,
        venueName: null,
        startDatetime: null,
      }),
      { status: 200, headers: responseHeaders(CACHE_CONTROL_FALLBACK) },
    );
  }

  const supabase = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: eventRow, error } = await supabase
    .from("public_events")
    .select("id,title,description,venue_name,start_datetime,images")
    .eq("id", eventId)
    .maybeSingle();

  if (error || !eventRow) {
    return new Response(
      renderHtml({
        title: FALLBACK_TITLE,
        description: FALLBACK_DESCRIPTION,
        ogImageUrl: `${requestUrl.origin}/og-fallback.png`,
        ogUrl,
        noIndex: true,
        eventId,
        venueName: null,
        startDatetime: null,
      }),
      { status: 200, headers: responseHeaders(CACHE_CONTROL_FALLBACK) },
    );
  }

  const event = eventRow as PublicEventRow;
  const ogImageUrl = pickOgImage(event.images, requestUrl.origin);
  const description = truncateOgDescription(event.description);

  return new Response(
    renderHtml({
      title: event.title,
      description,
      ogImageUrl,
      ogUrl,
      noIndex: false,
      eventId: event.id,
      venueName: event.venue_name,
      startDatetime: event.start_datetime,
    }),
    { status: 200, headers: responseHeaders(CACHE_CONTROL_SUCCESS) },
  );
}

if (import.meta.main) {
  Deno.serve(handleShareOg);
}
