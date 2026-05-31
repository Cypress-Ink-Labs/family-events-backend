import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";

const SITE_URL = "https://family-events.org";

// Cache the sitemap at the edge for 1 hour; stale-while-revalidate keeps the
// previous version served while the next one is generated.
const CACHE_CONTROL = "public, max-age=3600, s-maxage=3600, stale-while-revalidate=600";

// ── Static pages ────────────────────────────────────────────────────────────

const STATIC_PAGES: Array<{ path: string; changefreq: string; priority: string }> = [
  { path: "/", changefreq: "daily", priority: "1.0" },
  { path: "/explore", changefreq: "daily", priority: "0.9" },
  { path: "/calendar", changefreq: "daily", priority: "0.7" },
  { path: "/map", changefreq: "daily", priority: "0.7" },
  { path: "/sign-in", changefreq: "monthly", priority: "0.5" },
  { path: "/sign-up", changefreq: "monthly", priority: "0.5" },
  { path: "/privacy", changefreq: "yearly", priority: "0.3" },
  { path: "/terms", changefreq: "yearly", priority: "0.3" },
];

// ── Helpers ─────────────────────────────────────────────────────────────────

function escapeXml(str: string): string {
  return str
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("'", "&apos;")
    .replaceAll('"', "&quot;");
}

function toW3CDate(iso: string): string {
  // Sitemap dates should be YYYY-MM-DD or full W3C datetime.
  try {
    return new Date(iso).toISOString().split("T")[0];
  } catch {
    return new Date().toISOString().split("T")[0];
  }
}

// ── Robots.txt ──────────────────────────────────────────────────────────────

function robotsTxt(origin: string): Response {
  const body = [
    "User-agent: *",
    "Allow: /",
    "",
    "# Auth and admin areas",
    "Disallow: /admin",
    "Disallow: /auth/callback",
    "Disallow: /reset-password",
    "",
    `Sitemap: ${origin}/sitemap.xml`,
  ].join("\n");

  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": CACHE_CONTROL,
    },
  });
}

// ── Sitemap.xml ─────────────────────────────────────────────────────────────

interface PublicEvent {
  id: string;
  title: string;
  start_datetime: string;
}

async function sitemapXml(origin: string): Promise<Response> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  let events: PublicEvent[] = [];

  if (supabaseUrl && anonKey) {
    const supabase = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data, error } = await supabase
      .from("public_events")
      .select("id, title, start_datetime")
      .order("start_datetime", { ascending: false })
      .limit(5000);

    if (!error && data) {
      events = data as PublicEvent[];
    }
  }

  const today = new Date().toISOString().split("T")[0];

  const urls: string[] = [];

  // Static pages
  for (const page of STATIC_PAGES) {
    urls.push(
      `  <url>`,
      `    <loc>${escapeXml(`${origin}${page.path}`)}</loc>`,
      `    <lastmod>${today}</lastmod>`,
      `    <changefreq>${page.changefreq}</changefreq>`,
      `    <priority>${page.priority}</priority>`,
      `  </url>`,
    );
  }

  // Event detail pages
  for (const event of events) {
    const lastmod = toW3CDate(event.start_datetime);
    urls.push(
      `  <url>`,
      `    <loc>${escapeXml(`${origin}/events/${event.id}`)}</loc>`,
      `    <lastmod>${lastmod}</lastmod>`,
      `    <changefreq>weekly</changefreq>`,
      `    <priority>0.8</priority>`,
      `  </url>`,
    );
  }

  const xml = [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`,
    ...urls,
    `</urlset>`,
  ].join("\n");

  return new Response(xml, {
    status: 200,
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      "Cache-Control": CACHE_CONTROL,
    },
  });
}

// ── Handler ─────────────────────────────────────────────────────────────────

export async function handleSitemap(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const origin = SITE_URL;

  // Route based on path: /robots.txt vs /sitemap.xml (default)
  if (url.pathname.endsWith("/robots.txt") || url.searchParams.get("type") === "robots") {
    return robotsTxt(origin);
  }

  return sitemapXml(origin);
}

if (import.meta.main) {
  Deno.serve(handleSitemap);
}
