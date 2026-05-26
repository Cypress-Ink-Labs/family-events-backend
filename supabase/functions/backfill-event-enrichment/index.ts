import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { requireServiceRole } from "../_shared/auth.ts";
import {
  cronRunContextFromRequest,
  logCronRunEvent,
} from "../_shared/cron-run-log.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, errorMessage } from "../_shared/logger.ts";
import { buildGeocodeQuery, geocodeViaNominatim } from "../_shared/geocode.ts";
import {
  findFallbackImage,
  lookupUnsplashPhotoFromUrl,
  trackUnsplashDownload,
} from "../_shared/unsplash.ts";
import { sanitizeImagesForIngest } from "../scrape-source/lib/enrichment.ts";
import type { ParsedEvent } from "../scrape-source/lib/types.ts";
import { runParentTipsPass } from "./parent-tips-pass.ts";

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

// Parent-tips pass is gated by ai_feature_config and runs after the
// coords/images loop. Smaller batch because each event = one LLM call
// (~1-3s) on top of the work already done above.
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
   * Tag slugs ordered by confidence DESC. Migration 20260601004000
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

interface PendingUnsplashTrackingRow {
  attribution_id: string;
  event_id: string;
  image_url: string;
  download_location: string;
  attempts: number;
}

interface UnsplashTrackingSummary {
  pending_claimed: number;
  tracked: number;
  failed: number;
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
  let unsplashResult: Awaited<ReturnType<typeof findFallbackImage>> = null;

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
      } else {
        // When venue_name follows "Room Name, Branch Name" pattern (e.g.
        // "WRL Storytime Room, West Regional Library"), Nominatim can't resolve
        // the room prefix. Strip it and retry with just the branch name.
        const raw = row.venue_name ?? row.address;
        if (raw) {
          const lastComma = raw.lastIndexOf(",");
          if (lastComma !== -1) {
            const branchName = raw.substring(lastComma + 1).trim();
            if (branchName) {
              const fallbackQuery = buildGeocodeQuery({
                address: null,
                venueName: branchName,
                cityName: cityCtx?.name ?? null,
                cityState: cityCtx?.state ?? null,
              });
              if (fallbackQuery) {
                const fallbackGeo = await geocodeViaNominatim(fallbackQuery);
                if (fallbackGeo) {
                  latitude = fallbackGeo.latitude;
                  longitude = fallbackGeo.longitude;
                }
              }
            }
          }
        }
      }
    }

    // Third-tier fallback: venue name without any city context. Some venues
    // embed a different city in their name (e.g. "Broussard Sports Complex"
    // when the event's city_id points to Lafayette). Nominatim rejects the
    // query when the appended city contradicts the venue's actual location.
    // Retrying with the raw venue_name alone lets Nominatim resolve the
    // place using its own geographic context.
    if (latitude === null && row.venue_name) {
      const venueOnlyQuery = buildGeocodeQuery({
        address: null,
        venueName: row.venue_name,
        cityName: null,
        cityState: null,
      });
      if (venueOnlyQuery && venueOnlyQuery !== query) {
        const venueGeo = await geocodeViaNominatim(venueOnlyQuery);
        if (venueGeo) {
          latitude = venueGeo.latitude;
          longitude = venueGeo.longitude;
        }
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
    unsplashResult = await findFallbackImage(row.tags, unsplashAccessKey);
    if (unsplashResult) {
      images = [unsplashResult.url];
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
    return {
      updated: false,
      gotCoords: false,
      gotImages: false,
      imageSource: "none",
    };
  }

  // update_event_enrichment also bumps last_enrichment_attempt_at server-side.
  if (imageSource === "unsplash" && unsplashResult) {
    const { data: attributionId, error } = await supabase.rpc(
      "upsert_event_image_attribution_with_enrichment",
      {
        p_event_id: row.event_id,
        p_latitude: latitude,
        p_longitude: longitude,
        p_images: images,
        p_image_url: unsplashResult.url,
        p_unsplash_photo_id: unsplashResult.attribution.photoId,
        p_unsplash_photographer_name:
          unsplashResult.attribution.photographerName,
        p_unsplash_photographer_username:
          unsplashResult.attribution.photographerUsername,
        p_unsplash_photographer_profile_url:
          unsplashResult.attribution.photographerProfileUrl,
        p_unsplash_photo_url: unsplashResult.attribution.photoUrl,
        p_unsplash_download_location:
          unsplashResult.attribution.downloadLocation,
        p_matched_tag: unsplashResult.matchedTag,
      },
    );
    if (error) throw error;

    if (typeof attributionId === "string" && attributionId.length > 0) {
      const tracking = await trackUnsplashDownload(
        unsplashResult.attribution.downloadLocation,
        unsplashAccessKey,
      );
      const { error: markTrackingError } = await supabase.rpc(
        "mark_unsplash_download_tracking_result",
        {
          p_attribution_id: attributionId,
          p_success: tracking.ok,
          p_error: tracking.error,
        },
      );
      if (markTrackingError) throw markTrackingError;
    }
  } else {
    const { error } = await supabase.rpc("update_event_enrichment", {
      p_event_id: row.event_id,
      p_latitude: latitude,
      p_longitude: longitude,
      p_images: images.length > 0 ? images : null,
    });
    if (error) throw error;
  }

  return { updated: true, gotCoords, gotImages, imageSource };
}

async function runPendingUnsplashTrackingPass(
  supabase: SupabaseClient,
  unsplashAccessKey: string,
): Promise<UnsplashTrackingSummary> {
  const summary: UnsplashTrackingSummary = {
    pending_claimed: 0,
    tracked: 0,
    failed: 0,
  };

  if (!unsplashAccessKey) return summary;

  const { data, error } = await supabase.rpc(
    "list_pending_unsplash_download_tracking",
    {
      p_limit: 25,
    },
  );
  if (error) throw error;

  const rows = (data ?? []) as PendingUnsplashTrackingRow[];
  summary.pending_claimed = rows.length;

  for (const row of rows) {
    const result = await trackUnsplashDownload(
      row.download_location,
      unsplashAccessKey,
    );
    const { error: markError } = await supabase.rpc(
      "mark_unsplash_download_tracking_result",
      {
        p_attribution_id: row.attribution_id,
        p_success: result.ok,
        p_error: result.error,
      },
    );
    if (markError) throw markError;
    if (result.ok) summary.tracked += 1;
    else summary.failed += 1;
  }

  return summary;
}

interface AttributionBackfillRow {
  event_id: string;
  image_url: string;
}

interface AttributionBackfillSummary {
  claimed: number;
  backfilled: number;
  skipped: number;
  errors: number;
}

const ATTRIBUTION_BACKFILL_BATCH = 10;

async function runUnsplashAttributionBackfillPass(
  supabase: SupabaseClient,
  unsplashAccessKey: string,
): Promise<AttributionBackfillSummary> {
  const summary: AttributionBackfillSummary = {
    claimed: 0,
    backfilled: 0,
    skipped: 0,
    errors: 0,
  };

  if (!unsplashAccessKey) return summary;

  const { data, error } = await supabase.rpc(
    "list_events_needing_attribution_backfill",
    { p_limit: ATTRIBUTION_BACKFILL_BATCH },
  );
  if (error) throw error;

  const rows = (data ?? []) as AttributionBackfillRow[];
  summary.claimed = rows.length;

  for (const row of rows) {
    try {
      const attribution = await lookupUnsplashPhotoFromUrl(
        row.image_url,
        unsplashAccessKey,
      );

      if (!attribution) {
        summary.skipped += 1;
        continue;
      }

      const { error: upsertErr } = await supabase
        .from("event_image_attributions")
        .upsert(
          {
            event_id: row.event_id,
            image_url: row.image_url,
            provider: "unsplash",
            matched_tag: null,
            unsplash_photo_id: attribution.photoId,
            unsplash_photographer_name: attribution.photographerName,
            unsplash_photographer_username: attribution.photographerUsername,
            unsplash_photographer_profile_url:
              attribution.photographerProfileUrl,
            unsplash_photo_url: attribution.photoUrl,
            unsplash_download_location: attribution.downloadLocation,
            download_tracking_status: "pending",
            download_tracking_next_attempt_at: new Date().toISOString(),
          },
          { onConflict: "event_id,image_url" },
        );

      if (upsertErr) {
        summary.errors += 1;
        continue;
      }

      summary.backfilled += 1;
    } catch (rowErr) {
      summary.errors += 1;
    }
  }

  return summary;
}

Deno.serve(async (req: Request) => {
  const cronContext = cronRunContextFromRequest(req);

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
      supabase.rpc("backfill_image_enrichment_in_scope", {
        p_limit: halfBatch,
      }),
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
        if (result.imageSource === "unsplash") {
          summary.images_from_unsplash += 1;
        }
      } catch (rowErr) {
        summary.errors += 1;
        await logCronRunEvent(
          supabase,
          cronContext,
          "warn",
          "enrich row failed",
          {
            function: "backfill-event-enrichment",
            event_id: row.event_id,
            error: errorMessage(rowErr),
          },
        );
      }
    }

    const unsplashTrackingSummary = await runPendingUnsplashTrackingPass(
      supabase,
      unsplashAccessKey,
    );

    const attributionBackfillSummary = await runUnsplashAttributionBackfillPass(
      supabase,
      unsplashAccessKey,
    );

    const parentTipsSummary = await runParentTipsPass({
      supabase,
      supabaseUrl,
      serviceRoleKey,
      cronContext,
    });

    await logCronRunEvent(
      supabase,
      cronContext,
      "log",
      "backfill-event-enrichment done",
      {
        function: "backfill-event-enrichment",
        ...summary,
        unsplash_tracking: unsplashTrackingSummary,
        attribution_backfill: attributionBackfillSummary,
        parent_tips: parentTipsSummary,
      },
    );
    return new Response(
      JSON.stringify({
        ok: true,
        ...summary,
        unsplash_tracking: unsplashTrackingSummary,
        attribution_backfill: attributionBackfillSummary,
        parent_tips: parentTipsSummary,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (err) {
    if (serviceRoleKey && supabaseUrl) {
      const supabase = createClient(supabaseUrl, serviceRoleKey);
      await logCronRunEvent(
        supabase,
        cronContext,
        "error",
        "backfill-event-enrichment failed",
        errorContext(err, {
          function: "backfill-event-enrichment",
          stage: "outer",
        }),
      );
    }
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
