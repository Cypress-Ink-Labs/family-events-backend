import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { requireServiceRole } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, errorMessage, logEdgeEvent } from "../_shared/logger.ts";
import { buildGeocodeQuery, geocodeViaNominatim } from "../_shared/geocode.ts";
import { findFallbackImage } from "../_shared/unsplash.ts";
import { sanitizeImagesForIngest } from "../scrape-source/lib/enrichment.ts";
import type { ParsedEvent } from "../scrape-source/lib/types.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

// Cap batch so per-tick wall stays under 90s with headroom under the 150s
// edge wall. Each event = 1 geocode HTTP + N image HEAD HTTPs (capped at 5)
// + optionally 1 Unsplash search + 1 download-track ping. At ~1-3s/event
// we fit ~25-30 events comfortably.
const DEFAULT_BATCH = 25;

interface EventNeedingEnrichment {
  event_id: string;
  title: string;
  description: string | null;
  venue_name: string | null;
  address: string | null;
  city_id: string | null;
  source_id: string | null;
  source_url: string | null;
  needs_coords: boolean;
  needs_images: boolean;
  admin_locked_fields: string[];
  /**
   * Tag slugs ordered by confidence DESC. Migration 20260601009100
   * extends list_events_needing_enrichment + adds
   * backfill_image_enrichment_in_scope so both return this column.
   * Empty array when the tag-queue hasn't processed the event yet.
   */
  tags: string[];
}

interface SourceCityContext {
  name: string | null;
  state: string | null;
  latitude: number | null;
  longitude: number | null;
}

async function fetchCityContext(
  supabase: SupabaseClient,
  cityId: string | null,
): Promise<SourceCityContext | null> {
  if (!cityId) return null;
  const { data } = await supabase
    .from("cities")
    .select("name, state, latitude, longitude")
    .eq("id", cityId)
    .maybeSingle();
  if (!data) return null;
  return {
    name: data.name,
    state: data.state,
    latitude: data.latitude,
    longitude: data.longitude,
  };
}

async function fetchSourceUrl(
  supabase: SupabaseClient,
  sourceId: string | null,
): Promise<string | null> {
  if (!sourceId) return null;
  const { data } = await supabase
    .from("event_sources")
    .select("url")
    .eq("id", sourceId)
    .maybeSingle();
  return (data as { url?: string } | null)?.url ?? null;
}

async function enrichOne(
  supabase: SupabaseClient,
  row: EventNeedingEnrichment,
  cityCache: Map<string, SourceCityContext | null>,
  sourceCache: Map<string, string | null>,
  unsplashAccessKey: string,
): Promise<{
  updated: boolean;
  gotCoords: boolean;
  gotImages: boolean;
  imageSource: "scraper" | "unsplash" | "none";
}> {
  let latitude: number | null = null;
  let longitude: number | null = null;
  let images: string[] = [];
  let imageSource: "scraper" | "unsplash" | "none" = "none";

  if (row.needs_coords) {
    let cityCtx: SourceCityContext | null = null;
    if (row.city_id) {
      if (!cityCache.has(row.city_id)) {
        cityCache.set(
          row.city_id,
          await fetchCityContext(supabase, row.city_id),
        );
      }
      cityCtx = cityCache.get(row.city_id) ?? null;
    }

    const query = buildGeocodeQuery({
      address: row.address,
      venueName: row.venue_name,
      cityName: cityCtx?.name ?? null,
      cityState: cityCtx?.state ?? null,
    });
    if (query) {
      const geo = await geocodeViaNominatim(query);
      if (geo) {
        latitude = geo.latitude;
        longitude = geo.longitude;
      }
    }
    // Intentionally no city-centroid fallback here. Writing the centroid back
    // re-flags the row as needs_coords (centroid match) and the claim queue
    // re-served the same rows every tick, starving the rest of the backlog.
    // Scrape already seeds the centroid on insert; if the geocode misses we
    // leave the row at its existing coords and the attempt-timestamp bump
    // (mark_event_enrichment_attempt below) rotates it to the back of the
    // queue so other rows get a turn.
  }

  if (row.needs_images && row.source_id) {
    if (!sourceCache.has(row.source_id)) {
      sourceCache.set(
        row.source_id,
        await fetchSourceUrl(supabase, row.source_id),
      );
    }
    const sourceUrl = sourceCache.get(row.source_id) ?? null;
    if (sourceUrl) {
      // sanitizeImagesForIngest expects a ParsedEvent shape; the scrape
      // RPC drops the parser's images on insert, so this currently returns
      // []. Left as the "real scraped images" path — any future change
      // that preserves parser output lands here without touching the
      // Unsplash fallback below.
      const parsedShim: ParsedEvent = {
        title: row.title,
        description: row.description ?? "",
        startDatetime: new Date().toISOString(),
        endDatetime: null,
        venueName: row.venue_name,
        address: row.address,
        sourceUrl: row.source_url,
        imageUrl: null,
        images: [],
        price: null,
        isFree: false,
      };
      images = await sanitizeImagesForIngest(parsedShim, sourceUrl);
      if (images.length > 0) imageSource = "scraper";
    }
  }

  // Tag-keyed Unsplash fallback. Only fires when (a) the row needs images,
  // (b) the scraper path didn't produce any, (c) tag-queue has classified
  // the event, and (d) we have an API key. Failure leaves images empty
  // and the row stays on the queue for the next tick.
  if (row.needs_images && images.length === 0 && row.tags.length > 0) {
    const result = await findFallbackImage(row.tags, unsplashAccessKey);
    if (result) {
      images = [result.url];
      imageSource = "unsplash";
    }
  }

  const gotCoords = latitude !== null && longitude !== null;
  const gotImages = images.length > 0;

  // Nothing to write: bump the attempt timestamp so the row rotates to the
  // back of the claim queue. Without this the same unfillable rows would
  // sit at the top of the ORDER BY tiebreaker forever, starving the rest
  // of the backlog.
  if (!gotCoords && !gotImages) {
    const { error: markErr } = await supabase.rpc(
      "mark_event_enrichment_attempt",
      { p_event_id: row.event_id },
    );
    if (markErr) throw markErr;
    return { updated: false, gotCoords: false, gotImages: false, imageSource: "none" };
  }

  // update_event_enrichment also bumps last_enrichment_attempt_at server-side.
  const { error } = await supabase.rpc("update_event_enrichment", {
    p_event_id: row.event_id,
    p_latitude: latitude,
    p_longitude: longitude,
    p_images: images.length > 0 ? images : null,
  });
  if (error) throw error;

  return { updated: true, gotCoords, gotImages, imageSource };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";

  const auth = requireServiceRole(req, serviceRoleKey);
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (!supabaseUrl) {
    return new Response(
      JSON.stringify({ error: "SUPABASE_URL not configured" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  try {
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const unsplashAccessKey = Deno.env.get("UNSPLASH_ACCESS_KEY") ?? "";

    // Two-pass row claim. The legacy RPC orders by created_at DESC so old
    // rows that already have coords but no images can starve when many
    // recently-scraped rows still need coords. The scoped RPC narrows to
    // featured + next-30-day rows so the user-facing surface fills first.
    const halfBatch = Math.max(1, Math.floor(DEFAULT_BATCH / 2));
    const [legacyResp, scopedResp] = await Promise.all([
      supabase.rpc("list_events_needing_enrichment", { p_limit: halfBatch }),
      supabase.rpc("backfill_image_enrichment_in_scope", { p_limit: halfBatch }),
    ]);
    if (legacyResp.error) throw legacyResp.error;
    if (scopedResp.error) throw scopedResp.error;

    const seen = new Set<string>();
    const rows: EventNeedingEnrichment[] = [];
    for (const r of ((legacyResp.data ?? []) as EventNeedingEnrichment[])) {
      if (!seen.has(r.event_id)) {
        seen.add(r.event_id);
        rows.push(r);
      }
    }
    for (const r of ((scopedResp.data ?? []) as EventNeedingEnrichment[])) {
      if (!seen.has(r.event_id)) {
        seen.add(r.event_id);
        rows.push(r);
      }
    }

    const summary = {
      claimed: rows.length,
      updated: 0,
      coords: 0,
      images: 0,
      images_from_scraper: 0,
      images_from_unsplash: 0,
      errors: 0,
    };
    const cityCache = new Map<string, SourceCityContext | null>();
    const sourceCache = new Map<string, string | null>();

    for (const row of rows) {
      try {
        const result = await enrichOne(
          supabase,
          row,
          cityCache,
          sourceCache,
          unsplashAccessKey,
        );
        if (result.updated) summary.updated += 1;
        if (result.gotCoords) summary.coords += 1;
        if (result.gotImages) summary.images += 1;
        if (result.imageSource === "scraper") summary.images_from_scraper += 1;
        if (result.imageSource === "unsplash") summary.images_from_unsplash += 1;
      } catch (rowErr) {
        summary.errors += 1;
        logEdgeEvent("warn", "enrich row failed", {
          function: "backfill-event-enrichment",
          event_id: row.event_id,
          error: errorMessage(rowErr),
        });
      }
    }

    logEdgeEvent("log", "backfill-event-enrichment done", {
      function: "backfill-event-enrichment",
      ...summary,
    });
    return new Response(JSON.stringify({ ok: true, ...summary }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    await captureEdgeException(
      err,
      errorContext(err, {
        function: "backfill-event-enrichment",
        stage: "outer",
      }),
    );
    return new Response(JSON.stringify({ error: errorMessage(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
