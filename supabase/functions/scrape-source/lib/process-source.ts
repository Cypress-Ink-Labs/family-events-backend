import type { SupabaseClient } from "@supabase/supabase-js";
import { captureEdgeException } from "../../_shared/sentry.ts";
import { errorContext, logEdgeEvent } from "../../_shared/logger.ts";
import {
  buildGeocodeQuery,
  geocodeViaNominatim,
} from "../../_shared/geocode.ts";
import { dedupKey } from "../../_shared/parsing.ts";
import { validateExternalUrl } from "../../_shared/url-validation.ts";
import { resolveAndCheckPublicIp } from "../../_shared/url-resolve.ts";
import type { ParserContext } from "../parsers/_lib/context.ts";
import { buildExistingEventIndex } from "./dedupe.ts";
import { resolveCityTimezone } from "./schedule.ts";
// tag-fanout retired in Phase 4 — replaced by event_tag_queue + cron worker.
// scrape-source now just enqueues, returning immediately.
import type {
  EventSourceRow,
  ParsedEvent,
  RunStatus,
  SourceResult,
} from "./types.ts";

const SOURCE_FETCH_TIMEOUT_MS = 10_000;
const SOURCE_MAX_BYTES = 5 * 1024 * 1024; // 5 MB cap on feed body to prevent OOM
const IMAGE_HEAD_TIMEOUT_MS = 5_000;
const IMAGE_MAX_BYTES = 2 * 1024 * 1024;
const MAX_IMAGES_PER_EVENT = 5;
const IMAGE_VALIDATION_CONCURRENCY = 2;
const IMAGE_VALIDATION_TIMEOUT_MS = 6_000;
const IMAGE_HOST_ALLOWLIST_ENV = "SCRAPER_IMAGE_HOST_ALLOWLIST";
const LEGACY_IMAGE_HOST_ALLOWLIST_ENV = "SCRAPE_IMAGE_HOST_ALLOWLIST";

const OUTDOOR_TAG_HINTS = [
  "park",
  "outdoor",
  "hike",
  "nature",
  "trail",
  "playground",
];
const INDOOR_TAG_HINTS = ["museum", "indoor", "library", "theater", "theatre"];
const DEFAULT_IMAGE_HOST_ALLOWLIST = [
  "images.squarespace-cdn.com",
  "cdn.prod.website-files.com",
  "static.wixstatic.com",
  "images.unsplash.com",
];

type SourceCityContext = {
  name: string | null;
  state: string | null;
  latitude: number | null;
  longitude: number | null;
};

function applyAdminFieldLocks<T extends Record<string, unknown>>(
  payload: T,
  lockedFields: string[] | null | undefined,
): Partial<T> {
  const locked = new Set(lockedFields ?? []);
  return Object.fromEntries(
    Object.entries(payload).filter(([key]) => !locked.has(key)),
  ) as Partial<T>;
}

async function fetchAdminLockedFields(
  supabase: SupabaseClient,
  eventId: string,
): Promise<string[]> {
  const { data, error } = await supabase
    .from("events")
    .select("admin_locked_fields")
    .eq("id", eventId)
    .maybeSingle();

  if (error) {
    throw error;
  }
  return Array.isArray(data?.admin_locked_fields)
    ? data.admin_locked_fields
    : [];
}

function normalizeHost(value: string | null | undefined): string | null {
  if (!value) {
    return null;
  }
  return value.trim().toLowerCase().replace(/^\.+|\.+$/g, "") || null;
}

function uniqueHosts(hosts: Array<string | null | undefined>): string[] {
  const normalized = hosts
    .map((host) => normalizeHost(host))
    .filter((host): host is string => Boolean(host));
  return [...new Set(normalized)];
}

function hostFromUrl(url: string | null | undefined): string | null {
  if (!url) {
    return null;
  }
  try {
    return normalizeHost(new URL(url).hostname);
  } catch {
    return null;
  }
}

function hostAllowed(host: string, allowlist: string[]): boolean {
  const normalizedHost = normalizeHost(host);
  if (!normalizedHost) {
    return false;
  }
  return allowlist.some(
    (allowedHost) =>
      normalizedHost === allowedHost ||
      normalizedHost.endsWith(`.${allowedHost}`),
  );
}

function configuredImageHostAllowlist(): string[] {
  const envValue = Deno.env.get(IMAGE_HOST_ALLOWLIST_ENV) ??
    Deno.env.get(LEGACY_IMAGE_HOST_ALLOWLIST_ENV) ?? "";
  const configuredHosts = envValue
    .split(",")
    .map((entry) => normalizeHost(entry))
    .filter((entry): entry is string => Boolean(entry));
  return uniqueHosts([...DEFAULT_IMAGE_HOST_ALLOWLIST, ...configuredHosts]);
}

export function deriveIsOutdoorFromParsedEvent(
  parsed: ParsedEvent,
): boolean | null {
  const text = [
    parsed.title,
    parsed.description,
    parsed.venueName,
    parsed.address,
  ]
    .filter((value): value is string => Boolean(value))
    .join(" ")
    .toLowerCase();

  const hasOutdoorSignal = OUTDOOR_TAG_HINTS.some((keyword) =>
    text.includes(keyword)
  );
  const hasIndoorSignal = INDOOR_TAG_HINTS.some((keyword) =>
    text.includes(keyword)
  );

  if (hasOutdoorSignal && !hasIndoorSignal) {
    return true;
  }
  if (hasIndoorSignal && !hasOutdoorSignal) {
    return false;
  }
  return null;
}

async function measureImageByteLength(
  imageUrl: string,
): Promise<number | null> {
  // SSRF threat model: image URLs are already filtered by the static host
  // allowlist + protocol === "https:" + content-type check upstream. Adding a
  // DNS pre-check here would be belt-and-suspenders but breaks test isolation
  // (no way to mock Deno.resolveDns without a runtime hook). For sources fetched
  // via fetchSourceEvents — which have NO allowlist and accept arbitrary admin
  // URLs — the DNS check is mandatory.
  let response: Response;
  try {
    response = await fetch(imageUrl, {
      method: "GET",
      headers: {
        "User-Agent":
          "family-events-ingester/1.0 (+https://family-events.local)",
        Accept: "image/*",
      },
      // redirect: "error" — by this point the URL has already cleared the
      // HEAD allowlist re-check. Following a fresh GET-time redirect would
      // bypass that guard and re-open the SSRF surface (a server can serve a
      // benign HEAD and a redirect-to-internal-IP GET).
      redirect: "error",
      signal: AbortSignal.timeout(IMAGE_HEAD_TIMEOUT_MS),
    });
  } catch {
    return null;
  }

  if (!response.ok || !response.body) {
    return null;
  }

  const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("image/")) {
    return null;
  }

  const reader = response.body.getReader();
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      total += value.byteLength;
      if (total > IMAGE_MAX_BYTES) {
        await reader.cancel();
        return total;
      }
    }
  } catch {
    try {
      await reader.cancel();
    } catch {
      // Ignore cancel errors
    }
    return null;
  } finally {
    reader.releaseLock();
  }

  return total;
}

async function validateImageAtIngest(
  imageUrl: string,
  allowedHosts: string[],
): Promise<string | null> {
  const externalUrlValidation = validateExternalUrl(imageUrl);
  if (!externalUrlValidation.ok) {
    return null;
  }

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(imageUrl);
  } catch {
    return null;
  }

  if (parsedUrl.protocol !== "https:") {
    return null;
  }
  if (!hostAllowed(parsedUrl.hostname, allowedHosts)) {
    return null;
  }

  // See note in measureImageByteLength: allowlist + protocol + HEAD content-type
  // is the primary defense for images. Source feeds (no allowlist) use the DNS
  // pre-check.
  let response: Response;
  try {
    response = await fetch(parsedUrl.toString(), {
      method: "HEAD",
      headers: {
        "User-Agent":
          "family-events-ingester/1.0 (+https://family-events.local)",
        Accept: "image/*",
      },
      signal: AbortSignal.timeout(IMAGE_HEAD_TIMEOUT_MS),
    });
  } catch {
    return null;
  }

  if (!response.ok) {
    return null;
  }

  const responseUrl = response.url || parsedUrl.toString();
  const finalHost = hostFromUrl(responseUrl);
  if (!finalHost || !hostAllowed(finalHost, allowedHosts)) {
    return null;
  }

  let finalUrl: URL;
  try {
    finalUrl = new URL(responseUrl);
  } catch {
    return null;
  }
  if (finalUrl.protocol !== "https:") {
    return null;
  }

  const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("image/")) {
    return null;
  }

  const contentLengthHeader = response.headers.get("content-length");
  const contentLength = contentLengthHeader
    ? Number(contentLengthHeader)
    : null;
  const measuredLength = contentLengthHeader
    ? null
    : await measureImageByteLength(finalUrl.toString());
  const effectiveLength = contentLength ?? measuredLength;
  if (effectiveLength === null) {
    return null;
  }

  if (
    !Number.isFinite(effectiveLength) || effectiveLength <= 0 ||
    effectiveLength > IMAGE_MAX_BYTES
  ) {
    return null;
  }

  return finalUrl.toString();
}

function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
): Promise<T | null> {
  return new Promise((resolve) => {
    const timeoutId = setTimeout(() => resolve(null), timeoutMs);
    promise
      .then((value) => resolve(value))
      .catch(() => resolve(null))
      .finally(() => clearTimeout(timeoutId));
  });
}

export async function sanitizeImagesForIngest(
  parsed: ParsedEvent,
  sourceUrl: string,
): Promise<string[]> {
  const sourceHost = hostFromUrl(sourceUrl);
  const allowedHosts = uniqueHosts([
    sourceHost,
    ...configuredImageHostAllowlist(),
  ]);
  if (allowedHosts.length === 0) {
    return [];
  }

  // Cap the accepted images, not the raw candidates. If the first three
  // candidates fail validation but candidates 4-5 succeed, we want them.
  const imageCandidates = [
    ...new Set([
      ...parsed.images,
      ...(parsed.imageUrl ? [parsed.imageUrl] : []),
    ]),
  ];

  const validImages: string[] = [];
  let cursor = 0;

  while (
    cursor < imageCandidates.length && validImages.length < MAX_IMAGES_PER_EVENT
  ) {
    const batch = imageCandidates.slice(
      cursor,
      cursor + IMAGE_VALIDATION_CONCURRENCY,
    );
    cursor += batch.length;

    const results = await Promise.all(
      batch.map((imageCandidate) =>
        withTimeout(
          validateImageAtIngest(imageCandidate, allowedHosts),
          IMAGE_VALIDATION_TIMEOUT_MS,
        )
      ),
    );

    for (const validatedImage of results) {
      if (!validatedImage || validImages.includes(validatedImage)) {
        continue;
      }
      validImages.push(validatedImage);
      if (validImages.length >= MAX_IMAGES_PER_EVENT) {
        break;
      }
    }
  }

  return validImages;
}

async function fetchSourceCityContext(
  supabase: SupabaseClient,
  cityId: string | null,
): Promise<SourceCityContext | null> {
  if (!cityId) {
    return null;
  }

  const { data, error } = await supabase
    .from("cities")
    .select("name, state, latitude, longitude")
    .eq("id", cityId)
    .maybeSingle();
  if (error || !data) {
    return null;
  }

  return {
    name: data.name,
    state: data.state,
    latitude: data.latitude,
    longitude: data.longitude,
  };
}

async function resolveCoordinatesForParsedEvent(
  parsed: ParsedEvent,
  cityContext: SourceCityContext | null,
): Promise<{ latitude: number | null; longitude: number | null }> {
  const geocodeQuery = buildGeocodeQuery({
    address: parsed.address,
    venueName: parsed.venueName,
    cityName: cityContext?.name ?? null,
    cityState: cityContext?.state ?? null,
  });

  if (geocodeQuery) {
    const geocoded = await geocodeViaNominatim(geocodeQuery);
    if (geocoded) {
      return { latitude: geocoded.latitude, longitude: geocoded.longitude };
    }
  }

  if (cityContext?.latitude != null && cityContext?.longitude != null) {
    return { latitude: cityContext.latitude, longitude: cityContext.longitude };
  }

  return { latitude: null, longitude: null };
}

async function readResponseBodyCapped(
  response: Response,
  maxBytes: number,
): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  const readNextChunk = async (): Promise<void> => {
    const { done, value } = await reader.read();
    if (done) return;

    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error(`Response body exceeded cap of ${maxBytes} bytes`);
    }

    chunks.push(value);
    await readNextChunk();
  };

  try {
    await readNextChunk();
  } finally {
    reader.releaseLock();
  }

  const buf = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    buf.set(c, offset);
    offset += c.byteLength;
  }
  return new TextDecoder("utf-8").decode(buf);
}

const DEFAULT_FETCH_ACCEPT = "text/html,application/xml,text/xml,*/*";

async function guardedFetchText(url: string, accept: string): Promise<string> {
  // DNS-resolution-time SSRF check. validateExternalUrl alone only catches IP
  // literals; resolveAndCheckPublicIp also rejects hostnames that resolve into
  // private/loopback/link-local ranges (e.g. 169.254.169.254 metadata, RFC1918).
  const validation = await resolveAndCheckPublicIp(url);
  if (!validation.ok) {
    throw new Error(`Source URL rejected by validator: ${validation.reason}`);
  }

  const response = await fetch(url, {
    headers: {
      "User-Agent": "family-events-ingester/1.0 (+https://family-events.local)",
      Accept: accept,
    },
    signal: AbortSignal.timeout(SOURCE_FETCH_TIMEOUT_MS),
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch source (${response.status})`);
  }

  // Streamed read with 5 MB cap. response.text() is unbounded; a malicious or
  // accidentally-huge feed could OOM the edge function.
  return await readResponseBodyCapped(response, SOURCE_MAX_BYTES);
}

export function buildParserContext(timezone: string): ParserContext {
  return {
    timezone,
    fetchText: (url, opts) =>
      guardedFetchText(url, opts?.accept ?? DEFAULT_FETCH_ACCEPT),
    fetchJson: async <T = unknown>(
      url: string,
      opts?: { accept?: string },
    ): Promise<T> => {
      const body = await guardedFetchText(
        url,
        opts?.accept ?? "application/json,*/*",
      );
      return JSON.parse(body) as T;
    },
  };
}

export async function processSource(
  supabase: SupabaseClient,
  source: EventSourceRow,
  runId: string,
  parsedEvents: ParsedEvent[],
): Promise<SourceResult> {
  let status: RunStatus = "success";
  let eventsFound = 0;
  let eventsImported = 0;
  let eventsSkipped = 0;
  let errorMessage: string | null = null;
  // Counts non-fatal enqueue failures (e.g. transient RLS/network) so the run
  // can be downgraded to 'partial' if any occurred. Fatal pipeline-deploy
  // errors (queue table missing) are tracked separately and short-circuit
  // the loop because no further work can succeed.
  let enqueueFailures = 0;
  let pipelineSetupError: string | null = null;

  // Flush live progress to source_runs so the UI can show incremental counts.
  const PROGRESS_BATCH = 5;
  async function flushProgress() {
    await supabase
      .from("source_runs")
      .update({
        events_found: eventsFound,
        events_imported: eventsImported,
        events_skipped: eventsSkipped,
      })
      .eq("id", runId);
  }

  try {
    const timezone = await resolveCityTimezone(supabase, source.city_id);
    eventsFound = parsedEvents.length;

    // Write total found immediately so the UI shows "X found" while import runs.
    await flushProgress();

    const sourceCityContext = await fetchSourceCityContext(
      supabase,
      source.city_id,
    );

    const validEvents = parsedEvents.filter((p) => {
      if (!p.title || !p.startDatetime) {
        eventsSkipped += 1;
        return false;
      }
      return true;
    });

    if (validEvents.length === 0) {
      await flushProgress();
    } else {
      // Pre-flight: which source_urls in this batch already exist for this
      // source? Lets us skip per-event geocode/image HTTP work for updates,
      // which is the long pole of the per-tick wall clock budget.
      const candidateUrls = validEvents
        .map((p) => p.sourceUrl)
        .filter((u): u is string => Boolean(u));
      const existingSet = new Set<string>();
      if (candidateUrls.length > 0) {
        const { data: existingRows, error: existingErr } = await supabase
          .from("events")
          .select("source_url")
          .eq("source_id", source.id)
          .in("source_url", candidateUrls);
        if (existingErr) throw existingErr;
        for (const row of (existingRows ?? []) as Array<{ source_url: string }>) {
          existingSet.add(row.source_url);
        }
      }

      const PREP_CONCURRENCY = 10;

      async function prepEventPayload(
        parsed: ParsedEvent,
      ): Promise<Record<string, unknown>> {
        const isExisting = Boolean(
          parsed.sourceUrl && existingSet.has(parsed.sourceUrl),
        );
        // Skip image + geocode HTTP for updates — the SQL bulk RPC keeps the
        // existing images/coords when those fields are admin-locked, and the
        // parser's images list rarely changes between scrapes anyway.
        const validatedImages = isExisting
          ? []
          : await sanitizeImagesForIngest(parsed, source.url);
        const isOutdoor = deriveIsOutdoorFromParsedEvent(parsed);
        const geocoded = isExisting
          ? { latitude: null, longitude: null }
          : await resolveCoordinatesForParsedEvent(parsed, sourceCityContext);

        return {
          title: parsed.title,
          description: parsed.description ?? null,
          start_datetime: parsed.startDatetime,
          end_datetime: parsed.endDatetime ?? null,
          timezone,
          venue_name: parsed.venueName ?? null,
          address: parsed.address ?? null,
          city_id: source.city_id,
          source_url: parsed.sourceUrl ?? null,
          source_name: source.name,
          images: validatedImages,
          price: parsed.price ?? null,
          is_free: Boolean(parsed.isFree),
          is_outdoor: isOutdoor,
          latitude: geocoded.latitude,
          longitude: geocoded.longitude,
          dedup_key: dedupKey(
            parsed.title,
            parsed.startDatetime,
            source.city_id,
          ),
        };
      }

      const payloads: Record<string, unknown>[] = [];
      for (let i = 0; i < validEvents.length; i += PREP_CONCURRENCY) {
        const chunk = validEvents.slice(i, i + PREP_CONCURRENCY);
        const prepared = await Promise.all(chunk.map(prepEventPayload));
        payloads.push(...prepared);
      }

      // Single bulk RPC: classify + INSERT + UPDATE + event_tag_queue enqueue
      // all in one SQL transaction. Replaces the prior per-event loop (which
      // blew the 150s edge function wall at ~145/605 events).
      const { data: bulkResult, error: bulkError } = await supabase.rpc(
        "bulk_import_scrape_events",
        {
          p_run_id: runId,
          p_source_id: source.id,
          p_events: payloads,
        },
      );
      if (bulkError) {
        if (bulkError.code === "42883" || bulkError.code === "42P01") {
          // RPC missing → phase-7 migration not applied yet. Surface loudly.
          pipelineSetupError =
            "bulk_import_scrape_events RPC missing. Run `supabase db push --linked` to apply migration 20260601007000.";
        } else {
          throw bulkError;
        }
      } else {
        const result = bulkResult as {
          imported?: number;
          updated?: number;
          skipped?: number;
          enqueued?: number;
        } | null;
        const imported = result?.imported ?? 0;
        const updated = result?.updated ?? 0;
        const skipped = result?.skipped ?? 0;
        const enqueued = result?.enqueued ?? 0;
        eventsImported = imported + updated;
        eventsSkipped += skipped;
        // The RPC enqueues into event_tag_queue under ON CONFLICT DO NOTHING.
        // If imported+updated > enqueued, some rows were already pending in
        // the queue from a prior run — benign, not an error.
        if (imported + updated > 0 && enqueued < imported + updated) {
          logEdgeEvent("log", "tag-queue enqueue partial (existing rows)", {
            function: "scrape-source",
            run_id: runId,
            imported,
            updated,
            enqueued,
          });
        }
      }

      await flushProgress();
    }

    // Status derivation precedence:
    //   1. pipelineSetupError (bulk RPC missing) → 'error' + actionable hint
    //   2. found events but imported none → 'partial'
    //   3. otherwise 'success' (default initial value)
    if (pipelineSetupError) {
      status = "error";
      errorMessage = pipelineSetupError;
    } else if (eventsImported === 0 && eventsFound > 0) {
      status = "partial";
    }
  } catch (error) {
    status = "error";
    errorMessage = error instanceof Error
      ? error.message
      : "Unknown scrape failure.";
    await captureEdgeException(
      error,
      errorContext(error, {
        function: "scrape-source",
        source_id: source.id,
        source_name: source.name,
        source_type: source.source_type,
        run_id: runId,
      }),
    );
    logEdgeEvent(
      "error",
      "scrape-source fetch failed",
      errorContext(error, {
        function: "scrape-source",
        source_id: source.id,
        source_name: source.name,
        source_type: source.source_type,
        run_id: runId,
      }),
    );
  } finally {
    // Finalization MUST run even when the catch handler itself throws (e.g.
    // a logging call fails) or when an unexpected error escapes after the
    // catch. Otherwise source_runs is left in 'running' state forever.
    try {
      await supabase
        .from("source_runs")
        .update({
          completed_at: new Date().toISOString(),
          status,
          events_found: eventsFound,
          events_imported: eventsImported,
          events_skipped: eventsSkipped,
          error_log: errorMessage,
        })
        .eq("id", runId);

      await supabase
        .from("event_sources")
        .update({
          last_scraped_at: new Date().toISOString(),
          last_status: status,
          // Only reset error_count on full success. A 'partial' run (events
          // found, none imported) used to clear the counter and mask persistent
          // failures; keep accumulating until a clean success.
          error_count: status === "success"
            ? 0
            : source.error_count + (status === "error" ? 1 : 0),
        })
        .eq("id", source.id);
      // Kick the tag-queue worker if we imported anything. The RPC fires
      // net.http_post (async) and returns immediately — scrape-source does not
      // wait for tagging to complete. Errors are intentionally swallowed so a
      // tagging hiccup never affects the scrape status.
      if (eventsImported > 0) {
        const { error: tagKickError } = await supabase.rpc(
          "invoke_process_tag_queue",
        );
        if (tagKickError) {
          logEdgeEvent(
            "warn",
            "tag-queue kick failed after source processing",
            {
              function: "process-source",
              source_id: source.id,
              run_id: runId,
              error: tagKickError.message,
            },
          );
        }
      }
    } catch (finalizeError) {
      await captureEdgeException(
        finalizeError,
        errorContext(finalizeError, {
          function: "scrape-source",
          source_id: source.id,
          source_name: source.name,
          run_id: runId,
          stage: "finalize",
        }),
      );
    }
  }

  return {
    sourceId: source.id,
    status,
    eventsFound,
    eventsImported,
    eventsSkipped,
    error: errorMessage,
  };
}
