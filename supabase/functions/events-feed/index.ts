import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";

const SITE_URL = "https://family-events.org";
const STABLE_UID_DOMAIN = "family-events.org";

// Cache 1 h at edge; events mutate, but a short stale-while-revalidate avoids
// hammering the DB on every request while keeping cancelled/updated events
// visible within a reasonable window. Mirror share-og's reasoning: longer TTLs
// can pin cancelled events. 1 h is the sitemap precedent for low-churn content.
const CACHE_CONTROL = "public, max-age=3600, s-maxage=3600, stale-while-revalidate=600";

// Feed page size. RFC 5545 / RSS 2.0 have no hard limit but calendar clients
// may struggle with very large feeds. 200 matches events_enriched_v2 max.
const FEED_LIMIT = 200;

// ── Types ────────────────────────────────────────────────────────────────────

type FeedEvent = {
  id: string;
  title: string;
  description: string | null;
  start_datetime: string;
  end_datetime: string | null;
  timezone: string | null;
  venue_name: string | null;
  address: string | null;
  source_url: string | null;
  recurrence_info: unknown;
};

// ── iCal escaping (RFC 5545 §3.3.11) ─────────────────────────────────────────
// Text values must escape: backslash → \\, semicolon → \;, comma → \,
// newline → \n (literal backslash-n per RFC). Do NOT use XML/HTML escaping.
function escapeIcalText(str: string): string {
  return str
    .replaceAll("\\", "\\\\")
    .replaceAll(";", "\\;")
    .replaceAll(",", "\\,")
    .replaceAll("\r\n", "\\n")
    .replaceAll("\n", "\\n")
    .replaceAll("\r", "\\n");
}

// ── XML / HTML escaping for RSS ───────────────────────────────────────────────
function escapeXml(str: string): string {
  return str
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("'", "&apos;")
    .replaceAll('"', "&quot;");
}

// ── Date helpers ──────────────────────────────────────────────────────────────

// iCal DATE-TIME in UTC: YYYYMMDDTHHmmssZ (RFC 5545 §3.3.5)
function toIcalDatetime(iso: string): string {
  try {
    const d = new Date(iso);
    const pad = (n: number, len = 2) => String(n).padStart(len, "0");
    return (
      `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
      `T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`
    );
  } catch {
    return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "").replace("Z", "Z");
  }
}

// RSS 2.0 pubDate: RFC-822 format
function toRfc822Date(iso: string): string {
  try {
    return new Date(iso).toUTCString();
  } catch {
    return new Date().toUTCString();
  }
}

// ── iCal fold (RFC 5545 §3.1): lines > 75 octets must be folded) ─────────────
function foldIcalLine(line: string): string {
  // Simple UTF-16 code-unit based fold; sufficient for ASCII-heavy content.
  // RFC 5545 §3.1: fold at 75 octets. We conservatively fold at 74 chars to
  // avoid splitting multi-byte sequences at a byte boundary.
  const MAX = 74;
  if (line.length <= MAX) return line;
  const parts: string[] = [];
  let pos = 0;
  parts.push(line.slice(0, MAX));
  pos = MAX;
  while (pos < line.length) {
    parts.push(" " + line.slice(pos, pos + MAX - 1));
    pos += MAX - 1;
  }
  return parts.join("\r\n");
}

// ── iCal serializer ───────────────────────────────────────────────────────────

export function serializeIcal(events: FeedEvent[], calName: string): string {
  const lines: string[] = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    `PRODID:-//${STABLE_UID_DOMAIN}//Events Feed//EN`,
    `X-WR-CALNAME:${escapeIcalText(calName)}`,
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
  ];

  for (const ev of events) {
    const dtstart = toIcalDatetime(ev.start_datetime);
    // Use end_datetime when available; fall back to dtstart + 1 h (common
    // calendar convention for events without an explicit end time).
    const dtend = ev.end_datetime
      ? toIcalDatetime(ev.end_datetime)
      : toIcalDatetime(new Date(new Date(ev.start_datetime).getTime() + 3600_000).toISOString());

    const uid = `${ev.id}@${STABLE_UID_DOMAIN}`;
    const url = `${SITE_URL}/events/${ev.id}`;

    const location = [ev.venue_name, ev.address].filter(Boolean).join(", ");

    lines.push("BEGIN:VEVENT");
    lines.push(foldIcalLine(`UID:${uid}`));
    lines.push(foldIcalLine(`DTSTART:${dtstart}`));
    lines.push(foldIcalLine(`DTEND:${dtend}`));
    lines.push(foldIcalLine(`SUMMARY:${escapeIcalText(ev.title)}`));
    if (ev.description) {
      lines.push(foldIcalLine(`DESCRIPTION:${escapeIcalText(ev.description)}`));
    }
    if (location) {
      lines.push(foldIcalLine(`LOCATION:${escapeIcalText(location)}`));
    }
    lines.push(foldIcalLine(`URL:${url}`));
    // Recurrence: emit single occurrences only for the spike.
    // recurrence_info is jsonb; see open questions in plan 016 for RRULE mapping.
    lines.push("END:VEVENT");
  }

  lines.push("END:VCALENDAR");

  // RFC 5545 §3.1: lines end with CRLF. Each item in `lines` was already
  // processed by foldIcalLine when pushed (for per-event properties) or is a
  // short envelope line well under 75 chars. Joining with \r\n produces the
  // final stream; folded multi-line items carry their own \r\n continuations.
  return lines.join("\r\n") + "\r\n";
}

// ── RSS 2.0 serializer ────────────────────────────────────────────────────────

export function serializeRss(events: FeedEvent[], channelTitle: string, feedUrl: string): string {
  const items = events.map((ev) => {
    const link = `${SITE_URL}/events/${ev.id}`;
    const pubDate = toRfc822Date(ev.start_datetime);
    const desc = ev.description ? escapeXml(ev.description) : "";
    return [
      "    <item>",
      `      <title>${escapeXml(ev.title)}</title>`,
      `      <link>${escapeXml(link)}</link>`,
      `      <guid isPermaLink="false">${escapeXml(ev.id)}</guid>`,
      `      <pubDate>${pubDate}</pubDate>`,
      desc ? `      <description>${desc}</description>` : "",
      "    </item>",
    ]
      .filter(Boolean)
      .join("\n");
  });

  return [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<rss version="2.0">`,
    `  <channel>`,
    `    <title>${escapeXml(channelTitle)}</title>`,
    `    <link>${escapeXml(SITE_URL)}</link>`,
    `    <description>Upcoming family events</description>`,
    `    <atom:link href="${escapeXml(feedUrl)}" rel="self" type="application/rss+xml" xmlns:atom="http://www.w3.org/2005/Atom"/>`,
    ...items,
    `  </channel>`,
    `</rss>`,
  ].join("\n");
}

// ── Feed query ────────────────────────────────────────────────────────────────

async function fetchPublishedEvents(cityId: string | null): Promise<FeedEvent[]> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  if (!supabaseUrl || !anonKey) return [];

  const supabase = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Use events_enriched_v2: public, granted to anon, supports city filter and
  // keyset pagination. Default status = 'published'. Limit 200 (RPC max).
  // Date filter: upcoming events only (start_datetime >= now).
  const { data, error } = await supabase.rpc("events_enriched_v2", {
    p_city_id: cityId ?? undefined,
    p_status: "published",
    p_date_from: new Date().toISOString(),
    p_limit: FEED_LIMIT,
  });

  if (error || !data) return [];

  return (data as FeedEvent[]).map((row) => ({
    id: row.id,
    title: row.title,
    description: row.description,
    start_datetime: row.start_datetime,
    end_datetime: row.end_datetime,
    timezone: row.timezone,
    venue_name: row.venue_name,
    address: row.address,
    source_url: row.source_url,
    recurrence_info: row.recurrence_info,
  }));
}

// ── Handler ───────────────────────────────────────────────────────────────────

export async function handleEventsFeed(req: Request): Promise<Response> {
  if (req.method !== "GET") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const url = new URL(req.url);
  const format = (url.searchParams.get("format") ?? "rss").toLowerCase();
  const cityId = url.searchParams.get("city") ?? null;

  if (format !== "ics" && format !== "rss") {
    return new Response('Invalid format. Use ?format=ics or ?format=rss', { status: 400 });
  }

  const events = await fetchPublishedEvents(cityId);
  const channelTitle = cityId ? `Family Events` : `Family Events`;

  if (format === "ics") {
    const body = serializeIcal(events, channelTitle);
    return new Response(body, {
      status: 200,
      headers: {
        "Content-Type": "text/calendar; charset=utf-8",
        "Content-Disposition": 'attachment; filename="family-events.ics"',
        "Cache-Control": CACHE_CONTROL,
      },
    });
  }

  // Default: RSS
  const feedUrl = url.toString();
  const body = serializeRss(events, channelTitle, feedUrl);
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "application/rss+xml; charset=utf-8",
      "Cache-Control": CACHE_CONTROL,
    },
  });
}

if (import.meta.main) {
  Deno.serve(handleEventsFeed);
}
