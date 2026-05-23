import type { SupabaseClient } from "@supabase/supabase-js";
import { captureEdgeException } from "../../_shared/sentry.ts";
import {
  errorContext,
  errorMessage as formatError,
  logEdgeEvent,
} from "../../_shared/logger.ts";
import { resolveAndCheckPublicIp } from "../../_shared/url-resolve.ts";
import type { ParserContext } from "./parser-context.ts";
import { resolveCityTimezone } from "./schedule.ts";
// tag-fanout retired in Phase 4 — replaced by event_tag_queue + cron worker.
// scrape-source now just enqueues, returning immediately.
import type {
  EventSourceRow,
  ParsedEvent,
  RunStatus,
  SourceResult,
} from "./types.ts";
export { sanitizeImagesForIngest } from "./enrichment.ts";

const SOURCE_FETCH_TIMEOUT_MS = 10_000;
const SOURCE_MAX_BYTES = 5 * 1024 * 1024; // 5 MB cap on feed body to prevent OOM

const OUTDOOR_TAG_HINTS = [
  "park",
  "outdoor",
  "hike",
  "nature",
  "trail",
  "playground",
];
const INDOOR_TAG_HINTS = ["museum", "indoor", "library", "theater", "theatre"];
const MAX_RAW_IMAGE_CANDIDATES = 20;

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

export function deriveRawImageCandidates(parsed: ParsedEvent): string[] {
  const seen = new Set<string>();
  const candidates = [...parsed.images, ...(parsed.imageUrl ? [parsed.imageUrl] : [])];

  for (const candidate of candidates) {
    const url = candidate.trim();
    if (!url.startsWith("http://") && !url.startsWith("https://")) continue;
    if (seen.has(url)) continue;
    seen.add(url);
    if (seen.size >= MAX_RAW_IMAGE_CANDIDATES) break;
  }

  return [...seen];
}

async function fetchCityCentroid(
  supabase: SupabaseClient,
  cityId: string | null,
): Promise<{ latitude: number | null; longitude: number | null } | null> {
  if (!cityId) return null;
  const { data } = await supabase
    .from("cities")
    .select("latitude, longitude")
    .eq("id", cityId)
    .maybeSingle();
  return data ?? null;
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

export async function importParsedSourceEvents(
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
  // Fatal pipeline-deploy errors (bulk RPC missing) short-circuit the run
  // because no further work can succeed. Non-fatal enqueue failures are
  // logged but don't propagate — the SQL bulk RPC handles them via
  // ON CONFLICT DO NOTHING and returns a count we cross-check below.
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
    const [timezone, cityCentroid] = await Promise.all([
      resolveCityTimezone(supabase, source.city_id),
      fetchCityCentroid(supabase, source.city_id),
    ]);
    eventsFound = parsedEvents.length;

    // Write total found immediately so the UI shows "X found" while import runs.
    await flushProgress();

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
      function prepEventPayload(
        parsed: ParsedEvent,
      ): Record<string, unknown> {
        const isOutdoor = deriveIsOutdoorFromParsedEvent(parsed);
        const imageCandidates = deriveRawImageCandidates(parsed);

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
          images: imageCandidates,
          price: parsed.price ?? null,
          is_free: Boolean(parsed.isFree),
          is_outdoor: isOutdoor,
          latitude: cityCentroid?.latitude ?? null,
          longitude: cityCentroid?.longitude ?? null,
        };
      }

      const payloads = validEvents.map(prepEventPayload);

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
    // formatError surfaces PostgrestError code + details (plain-object
    // errors don't pass `instanceof Error`, so the original code silently
    // collapsed them to "Unknown scrape failure").
    errorMessage = formatError(error) || "Unknown scrape failure.";
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
      // Kick the tag-queue worker if we imported anything. Each RPC call
      // fires net.http_post (async) and returns immediately, so this is a
      // fan-out, not a blocking loop. process-tag-queue claims BATCH_SIZE=20
      // events per invocation via SKIP LOCKED, so N kicks = up to N×20 events
      // drained in parallel — without waiting for the 1-min cron tick.
      //
      // Cap matches process-tag-queue CONCURRENCY×2 to leave headroom for
      // the OpenAI rate limit (the LLM is the actual bottleneck). The cron
      // */1 keeps backfilling whatever a burst leaves behind.
      if (eventsImported > 0) {
        const TAG_QUEUE_BATCH_SIZE = 20;
        const MAX_KICKS = 8;
        const kicks = Math.min(
          Math.max(1, Math.ceil(eventsImported / TAG_QUEUE_BATCH_SIZE)),
          MAX_KICKS,
        );
        const results = await Promise.allSettled(
          Array.from(
            { length: kicks },
            () => supabase.rpc("invoke_process_tag_queue"),
          ),
        );
        const failed = results.filter((r) => r.status === "rejected").length;
        if (failed > 0) {
          logEdgeEvent(
            "warn",
            "tag-queue kick(s) failed after source processing",
            {
              function: "process-source",
              source_id: source.id,
              run_id: runId,
              events_imported: eventsImported,
              kicks_attempted: kicks,
              kicks_failed: failed,
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
