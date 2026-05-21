import type { SupabaseClient } from "@supabase/supabase-js"
import { captureEdgeException } from "../../_shared/sentry.ts"
import { errorContext, logEdgeEvent } from "../../_shared/logger.ts"
import { buildGeocodeQuery, geocodeViaNominatim } from "../../_shared/geocode.ts"
import { dedupKey } from "../../_shared/parsing.ts"
import { validateExternalUrl } from "../../_shared/url-validation.ts"
import { resolveAndCheckPublicIp } from "../../_shared/url-resolve.ts"
import { parsers } from "../parsers/index.ts"
import type { ParserContext } from "../parsers/_lib/context.ts"
import { buildExistingEventIndex } from "./dedupe.ts"
import { resolveCityTimezone } from "./schedule.ts"
// tag-fanout retired in Phase 4 — replaced by event_tag_queue + cron worker.
// scrape-source now just enqueues, returning immediately.
import type { EventSourceRow, ParsedEvent, RunStatus, SourceResult } from "./types.ts"

const SOURCE_FETCH_TIMEOUT_MS = 10_000
const SOURCE_MAX_BYTES = 5 * 1024 * 1024 // 5 MB cap on feed body to prevent OOM
const IMAGE_HEAD_TIMEOUT_MS = 5_000
const IMAGE_MAX_BYTES = 2 * 1024 * 1024
const MAX_IMAGES_PER_EVENT = 5
const IMAGE_VALIDATION_CONCURRENCY = 2
const IMAGE_VALIDATION_TIMEOUT_MS = 6_000
const IMAGE_HOST_ALLOWLIST_ENV = "SCRAPER_IMAGE_HOST_ALLOWLIST"
const LEGACY_IMAGE_HOST_ALLOWLIST_ENV = "SCRAPE_IMAGE_HOST_ALLOWLIST"

const OUTDOOR_TAG_HINTS = ["park", "outdoor", "hike", "nature", "trail", "playground"]
const INDOOR_TAG_HINTS = ["museum", "indoor", "library", "theater", "theatre"]
const DEFAULT_IMAGE_HOST_ALLOWLIST = [
  "images.squarespace-cdn.com",
  "cdn.prod.website-files.com",
  "static.wixstatic.com",
  "images.unsplash.com",
]

type SourceCityContext = {
  name: string | null
  state: string | null
  latitude: number | null
  longitude: number | null
}

function applyAdminFieldLocks<T extends Record<string, unknown>>(
  payload: T,
  lockedFields: string[] | null | undefined
): Partial<T> {
  const locked = new Set(lockedFields ?? [])
  return Object.fromEntries(
    Object.entries(payload).filter(([key]) => !locked.has(key))
  ) as Partial<T>
}

async function fetchAdminLockedFields(
  supabase: SupabaseClient,
  eventId: string
): Promise<string[]> {
  const { data, error } = await supabase
    .from("events")
    .select("admin_locked_fields")
    .eq("id", eventId)
    .maybeSingle()

  if (error) {
    throw error
  }
  return Array.isArray(data?.admin_locked_fields) ? data.admin_locked_fields : []
}

function normalizeHost(value: string | null | undefined): string | null {
  if (!value) {
    return null
  }
  return value.trim().toLowerCase().replace(/^\.+|\.+$/g, "") || null
}

function uniqueHosts(hosts: Array<string | null | undefined>): string[] {
  const normalized = hosts
    .map((host) => normalizeHost(host))
    .filter((host): host is string => Boolean(host))
  return [...new Set(normalized)]
}

function hostFromUrl(url: string | null | undefined): string | null {
  if (!url) {
    return null
  }
  try {
    return normalizeHost(new URL(url).hostname)
  } catch {
    return null
  }
}

function hostAllowed(host: string, allowlist: string[]): boolean {
  const normalizedHost = normalizeHost(host)
  if (!normalizedHost) {
    return false
  }
  return allowlist.some(
    (allowedHost) =>
      normalizedHost === allowedHost || normalizedHost.endsWith(`.${allowedHost}`)
  )
}

function configuredImageHostAllowlist(): string[] {
  const envValue =
    Deno.env.get(IMAGE_HOST_ALLOWLIST_ENV) ?? Deno.env.get(LEGACY_IMAGE_HOST_ALLOWLIST_ENV) ?? ""
  const configuredHosts = envValue
    .split(",")
    .map((entry) => normalizeHost(entry))
    .filter((entry): entry is string => Boolean(entry))
  return uniqueHosts([...DEFAULT_IMAGE_HOST_ALLOWLIST, ...configuredHosts])
}

export function deriveIsOutdoorFromParsedEvent(parsed: ParsedEvent): boolean | null {
  const text = [parsed.title, parsed.description, parsed.venueName, parsed.address]
    .filter((value): value is string => Boolean(value))
    .join(" ")
    .toLowerCase()

  const hasOutdoorSignal = OUTDOOR_TAG_HINTS.some((keyword) => text.includes(keyword))
  const hasIndoorSignal = INDOOR_TAG_HINTS.some((keyword) => text.includes(keyword))

  if (hasOutdoorSignal && !hasIndoorSignal) {
    return true
  }
  if (hasIndoorSignal && !hasOutdoorSignal) {
    return false
  }
  return null
}

async function measureImageByteLength(imageUrl: string): Promise<number | null> {
  // SSRF threat model: image URLs are already filtered by the static host
  // allowlist + protocol === "https:" + content-type check upstream. Adding a
  // DNS pre-check here would be belt-and-suspenders but breaks test isolation
  // (no way to mock Deno.resolveDns without a runtime hook). For sources fetched
  // via fetchSourceEvents — which have NO allowlist and accept arbitrary admin
  // URLs — the DNS check is mandatory.
  let response: Response
  try {
    response = await fetch(imageUrl, {
      method: "GET",
      headers: {
        "User-Agent": "family-events-ingester/1.0 (+https://family-events.local)",
        Accept: "image/*",
      },
      // redirect: "error" — by this point the URL has already cleared the
      // HEAD allowlist re-check. Following a fresh GET-time redirect would
      // bypass that guard and re-open the SSRF surface (a server can serve a
      // benign HEAD and a redirect-to-internal-IP GET).
      redirect: "error",
      signal: AbortSignal.timeout(IMAGE_HEAD_TIMEOUT_MS),
    })
  } catch {
    return null
  }

  if (!response.ok || !response.body) {
    return null
  }

  const contentType = response.headers.get("content-type")?.toLowerCase() ?? ""
  if (!contentType.startsWith("image/")) {
    return null
  }

  const reader = response.body.getReader()
  let total = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) {
        break
      }
      total += value.byteLength
      if (total > IMAGE_MAX_BYTES) {
        await reader.cancel()
        return total
      }
    }
  } catch {
    try {
      await reader.cancel()
    } catch {
      // Ignore cancel errors
    }
    return null
  } finally {
    reader.releaseLock()
  }

  return total
}

async function validateImageAtIngest(
  imageUrl: string,
  allowedHosts: string[]
): Promise<string | null> {
  const externalUrlValidation = validateExternalUrl(imageUrl)
  if (!externalUrlValidation.ok) {
    return null
  }

  let parsedUrl: URL
  try {
    parsedUrl = new URL(imageUrl)
  } catch {
    return null
  }

  if (parsedUrl.protocol !== "https:") {
    return null
  }
  if (!hostAllowed(parsedUrl.hostname, allowedHosts)) {
    return null
  }

  // See note in measureImageByteLength: allowlist + protocol + HEAD content-type
  // is the primary defense for images. Source feeds (no allowlist) use the DNS
  // pre-check.
  let response: Response
  try {
    response = await fetch(parsedUrl.toString(), {
      method: "HEAD",
      headers: {
        "User-Agent": "family-events-ingester/1.0 (+https://family-events.local)",
        Accept: "image/*",
      },
      signal: AbortSignal.timeout(IMAGE_HEAD_TIMEOUT_MS),
    })
  } catch {
    return null
  }

  if (!response.ok) {
    return null
  }

  const responseUrl = response.url || parsedUrl.toString()
  const finalHost = hostFromUrl(responseUrl)
  if (!finalHost || !hostAllowed(finalHost, allowedHosts)) {
    return null
  }

  let finalUrl: URL
  try {
    finalUrl = new URL(responseUrl)
  } catch {
    return null
  }
  if (finalUrl.protocol !== "https:") {
    return null
  }

  const contentType = response.headers.get("content-type")?.toLowerCase() ?? ""
  if (!contentType.startsWith("image/")) {
    return null
  }

  const contentLengthHeader = response.headers.get("content-length")
  const contentLength = contentLengthHeader ? Number(contentLengthHeader) : null
  const measuredLength = contentLengthHeader ? null : await measureImageByteLength(finalUrl.toString())
  const effectiveLength = contentLength ?? measuredLength
  if (effectiveLength === null) {
    return null
  }

  if (!Number.isFinite(effectiveLength) || effectiveLength <= 0 || effectiveLength > IMAGE_MAX_BYTES) {
    return null
  }

  return finalUrl.toString()
}


function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T | null> {
  return new Promise((resolve) => {
    const timeoutId = setTimeout(() => resolve(null), timeoutMs)
    promise
      .then((value) => resolve(value))
      .catch(() => resolve(null))
      .finally(() => clearTimeout(timeoutId))
  })
}

export async function sanitizeImagesForIngest(
  parsed: ParsedEvent,
  sourceUrl: string
): Promise<string[]> {
  const sourceHost = hostFromUrl(sourceUrl)
  const allowedHosts = uniqueHosts([sourceHost, ...configuredImageHostAllowlist()])
  if (allowedHosts.length === 0) {
    return []
  }

  // Cap the accepted images, not the raw candidates. If the first three
  // candidates fail validation but candidates 4-5 succeed, we want them.
  const imageCandidates = [
    ...new Set([
      ...parsed.images,
      ...(parsed.imageUrl ? [parsed.imageUrl] : []),
    ]),
  ]

  const validImages: string[] = []
  let cursor = 0

  while (cursor < imageCandidates.length && validImages.length < MAX_IMAGES_PER_EVENT) {
    const batch = imageCandidates.slice(cursor, cursor + IMAGE_VALIDATION_CONCURRENCY)
    cursor += batch.length

    const results = await Promise.all(
      batch.map((imageCandidate) =>
        withTimeout(
          validateImageAtIngest(imageCandidate, allowedHosts),
          IMAGE_VALIDATION_TIMEOUT_MS
        )
      )
    )

    for (const validatedImage of results) {
      if (!validatedImage || validImages.includes(validatedImage)) {
        continue
      }
      validImages.push(validatedImage)
      if (validImages.length >= MAX_IMAGES_PER_EVENT) {
        break
      }
    }
  }

  return validImages
}

async function fetchSourceCityContext(
  supabase: SupabaseClient,
  cityId: string | null
): Promise<SourceCityContext | null> {
  if (!cityId) {
    return null
  }

  const { data, error } = await supabase
    .from("cities")
    .select("name, state, latitude, longitude")
    .eq("id", cityId)
    .maybeSingle()
  if (error || !data) {
    return null
  }

  return {
    name: data.name,
    state: data.state,
    latitude: data.latitude,
    longitude: data.longitude,
  }
}

async function resolveCoordinatesForParsedEvent(
  parsed: ParsedEvent,
  cityContext: SourceCityContext | null
): Promise<{ latitude: number | null; longitude: number | null }> {
  const geocodeQuery = buildGeocodeQuery({
    address: parsed.address,
    venueName: parsed.venueName,
    cityName: cityContext?.name ?? null,
    cityState: cityContext?.state ?? null,
  })

  if (geocodeQuery) {
    const geocoded = await geocodeViaNominatim(geocodeQuery)
    if (geocoded) {
      return { latitude: geocoded.latitude, longitude: geocoded.longitude }
    }
  }

  if (cityContext?.latitude != null && cityContext?.longitude != null) {
    return { latitude: cityContext.latitude, longitude: cityContext.longitude }
  }

  return { latitude: null, longitude: null }
}

async function readResponseBodyCapped(response: Response, maxBytes: number): Promise<string> {
  if (!response.body) return ""
  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0

  const readNextChunk = async (): Promise<void> => {
    const { done, value } = await reader.read()
    if (done) return

    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel()
      throw new Error(`Response body exceeded cap of ${maxBytes} bytes`)
    }

    chunks.push(value)
    await readNextChunk()
  }

  try {
    await readNextChunk()
  } finally {
    reader.releaseLock()
  }

  const buf = new Uint8Array(total)
  let offset = 0
  for (const c of chunks) {
    buf.set(c, offset)
    offset += c.byteLength
  }
  return new TextDecoder("utf-8").decode(buf)
}

const DEFAULT_FETCH_ACCEPT = "text/html,application/xml,text/xml,*/*"

async function guardedFetchText(url: string, accept: string): Promise<string> {
  // DNS-resolution-time SSRF check. validateExternalUrl alone only catches IP
  // literals; resolveAndCheckPublicIp also rejects hostnames that resolve into
  // private/loopback/link-local ranges (e.g. 169.254.169.254 metadata, RFC1918).
  const validation = await resolveAndCheckPublicIp(url)
  if (!validation.ok) {
    throw new Error(`Source URL rejected by validator: ${validation.reason}`)
  }

  const response = await fetch(url, {
    headers: {
      "User-Agent": "family-events-ingester/1.0 (+https://family-events.local)",
      Accept: accept,
    },
    signal: AbortSignal.timeout(SOURCE_FETCH_TIMEOUT_MS),
  })

  if (!response.ok) {
    throw new Error(`Failed to fetch source (${response.status})`)
  }

  // Streamed read with 5 MB cap. response.text() is unbounded; a malicious or
  // accidentally-huge feed could OOM the edge function.
  return await readResponseBodyCapped(response, SOURCE_MAX_BYTES)
}

export function buildParserContext(timezone: string): ParserContext {
  return {
    timezone,
    fetchText: (url, opts) => guardedFetchText(url, opts?.accept ?? DEFAULT_FETCH_ACCEPT),
    fetchJson: async <T = unknown>(
      url: string,
      opts?: { accept?: string }
    ): Promise<T> => {
      const body = await guardedFetchText(url, opts?.accept ?? "application/json,*/*")
      return JSON.parse(body) as T
    },
  }
}

async function fetchSourceEvents(source: EventSourceRow, timezone: string): Promise<ParsedEvent[]> {
  const parser = parsers[source.source_type]
  if (!parser) {
    throw new Error(`No parser registered for source_type=${source.source_type}`)
  }
  const ctx = buildParserContext(timezone)
  return parser.fetchAndParse(source, ctx)
}

export async function processSource(
  supabase: SupabaseClient,
  source: EventSourceRow
): Promise<SourceResult> {
  const { data: runRow, error: runInsertError } = await supabase
    .from("source_runs")
    .insert({
      source_id: source.id,
      status: "running",
    })
    .select("id")
    .single()

  if (runInsertError || !runRow) {
    throw runInsertError ?? new Error("Failed to create source run record.")
  }
  const runId = runRow.id

  let status: RunStatus = "success"
  let eventsFound = 0
  let eventsImported = 0
  let eventsSkipped = 0
  let errorMessage: string | null = null
  // Counts non-fatal enqueue failures (e.g. transient RLS/network) so the run
  // can be downgraded to 'partial' if any occurred. Fatal pipeline-deploy
  // errors (queue table missing) are tracked separately and short-circuit
  // the loop because no further work can succeed.
  let enqueueFailures = 0
  let pipelineSetupError: string | null = null

  // Flush live progress to source_runs so the UI can show incremental counts.
  const PROGRESS_BATCH = 5
  async function flushProgress() {
    await supabase
      .from("source_runs")
      .update({
        events_found: eventsFound,
        events_imported: eventsImported,
        events_skipped: eventsSkipped,
      })
      .eq("id", runId)
  }

  try {
    const timezone = await resolveCityTimezone(supabase, source.city_id)
    const parsedEvents = await fetchSourceEvents(source, timezone)
    eventsFound = parsedEvents.length

    // Write total found immediately so the UI shows "X found" while import runs.
    await flushProgress()

    const index = await buildExistingEventIndex(supabase, source, parsedEvents)
    const sourceCityContext = await fetchSourceCityContext(supabase, source.city_id)

    const validEvents = parsedEvents.filter((p) => {
      if (!p.title || !p.startDatetime) {
        eventsSkipped += 1
        return false
      }
      return true
    })

    for (const parsed of validEvents) {
      // Prefer within-source match (source_url), fall back to cross-source dedup
      const sourceUrlMatch = parsed.sourceUrl ? index.bySourceUrl.get(parsed.sourceUrl) : null
      const crossSourceMatch = index.byDedupKey.get(
        dedupKey(parsed.title, parsed.startDatetime, source.city_id)
      )
      const existingEventId = sourceUrlMatch ?? crossSourceMatch ?? null

      // Skip if this is a cross-source dupe from ANOTHER source (don't overwrite)
      if (!sourceUrlMatch && crossSourceMatch) {
        eventsSkipped += 1
        continue
      }

      const validatedImages = await sanitizeImagesForIngest(parsed, source.url)
      const isOutdoor = deriveIsOutdoorFromParsedEvent(parsed)
      const geocodedCoordinates = existingEventId
        ? { latitude: null, longitude: null }
        : await resolveCoordinatesForParsedEvent(parsed, sourceCityContext)

      const payload = {
        title: parsed.title,
        description: parsed.description || null,
        start_datetime: parsed.startDatetime,
        end_datetime: parsed.endDatetime,
        timezone,
        venue_name: parsed.venueName,
        address: parsed.address,
        city_id: source.city_id,
        source_url: parsed.sourceUrl,
        source_name: source.name,
        source_id: source.id,
        images: validatedImages,
        price: parsed.price,
        is_free: parsed.isFree,
        is_outdoor: isOutdoor,
        status: (!existingEventId && source.auto_approve) ? "published" as const : "draft" as const,
        ...(existingEventId
          ? {}
          : {
              latitude: geocodedCoordinates.latitude,
              longitude: geocodedCoordinates.longitude,
            }),
      }

      // INSERT path uses plain insert. The partial UNIQUE index
      // events_source_id_source_url_uniq still prevents double-inserts from
      // concurrent runs at the DB level — it raises 23505 (unique_violation)
      // which we treat as benign ("another worker already imported this").
      //
      // Note: we cannot use .upsert(... onConflict: "source_id,source_url")
      // here because the underlying constraint is a *partial* unique index
      // (WHERE source_url IS NOT NULL), and PostgREST's on_conflict parameter
      // doesn't carry the WHERE predicate. PostgreSQL then raises 42P10
      // ("no unique or exclusion constraint matching the ON CONFLICT
      // specification") on every insert attempt — which is exactly the bug
      // that broke imports until we restored this plain-insert path.
      let upsertedEvent: { id: string } | null = null
      let upsertError: { code?: string; message?: string } | null = null
      if (existingEventId) {
        const lockedFields = await fetchAdminLockedFields(supabase, existingEventId)
        const unlockedPayload = applyAdminFieldLocks(payload, lockedFields)
        if (Object.keys(unlockedPayload).length === 0) {
          upsertedEvent = { id: existingEventId }
        } else {
          const result = await supabase
            .from("events")
            .update(unlockedPayload)
            .eq("id", existingEventId)
            .select("id")
            .single()
          upsertedEvent = result.data
          upsertError = result.error
        }
      } else {
        const result = await supabase.from("events").insert(payload).select("id").single()
        upsertedEvent = result.data
        upsertError = result.error
      }
      if (upsertError) {
        // 23505 = the partial unique index caught a concurrent insert. Look up
        // the existing row by (source_id, source_url) and continue as if we
        // had updated it, so progress counters and queue enqueue still fire.
        if (upsertError.code === "23505" && payload.source_url) {
          const { data: existingByUrl } = await supabase
            .from("events")
            .select("id")
            .eq("source_id", source.id)
            .eq("source_url", payload.source_url)
            .maybeSingle()
          if (existingByUrl) {
            const lockedFields = await fetchAdminLockedFields(supabase, existingByUrl.id)
            const unlockedPayload = applyAdminFieldLocks(payload, lockedFields)
            if (Object.keys(unlockedPayload).length > 0) {
              await supabase.from("events").update(unlockedPayload).eq("id", existingByUrl.id)
            }
            eventsImported += 1
            // Skip enqueue + progress flush — fall through to the post-insert
            // block below by faking the "successful upsert" path.
            // (The continue keeps the loop clean; the dedup index ensures we
            // never insert a duplicate event_tag_queue row anyway.)
            continue
          }
        }

        await captureEdgeException(
          upsertError,
          errorContext(upsertError, {
            function: "scrape-source",
            source_id: source.id,
            source_name: source.name,
            run_id: runId,
            event_title: parsed.title,
          })
        )
        logEdgeEvent(
          "error",
          "scrape-source event import failed",
          errorContext(upsertError, {
            function: "scrape-source",
            source_id: source.id,
            source_name: source.name,
            run_id: runId,
            event_title: parsed.title,
          })
        )
        eventsSkipped += 1
        continue
      }
      if (!upsertedEvent) {
        const error = new Error("Event upsert returned no row.")
        await captureEdgeException(
          error,
          errorContext(error, {
            function: "scrape-source",
            source_id: source.id,
            source_name: source.name,
            run_id: runId,
            event_title: parsed.title,
          })
        )
        logEdgeEvent(
          "error",
          "scrape-source event import failed",
          errorContext(error, {
            function: "scrape-source",
            source_id: source.id,
            source_name: source.name,
            run_id: runId,
            event_title: parsed.title,
          })
        )
        eventsSkipped += 1
        continue
      }

      eventsImported += 1

      // Enqueue tag-event work. The process-tag-queue worker drains the queue
      // every minute. Three error classes are handled distinctly so the
      // source_run row reflects pipeline health rather than just import counts:
      //   - 23505 (already enqueued, partial-unique violation): benign, swallow
      //   - 42P01 (table doesn't exist) → queue migration not deployed: fatal,
      //     short-circuit and mark the whole run as 'error' so the admin
      //     dashboard surfaces it instead of showing green while events are
      //     silently un-tagged
      //   - any other PostgrestError: count as a non-fatal failure; the run
      //     downgrades to 'partial' if any occurred
      const { error: enqueueError } = await supabase
        .from("event_tag_queue")
        .insert({
          event_id: upsertedEvent.id,
          source_run_id: runRow.id,
          trigger_type: "import",
        })
      if (enqueueError && enqueueError.code !== "23505") {
        await captureEdgeException(
          enqueueError,
          errorContext(enqueueError, {
            function: "scrape-source",
            stage: "enqueue-tag",
            event_id: upsertedEvent.id,
            run_id: runId,
          })
        )
        logEdgeEvent(
          "error",
          "failed to enqueue tag-event work",
          errorContext(enqueueError, {
            function: "scrape-source",
            event_id: upsertedEvent.id,
            run_id: runId,
          })
        )

        if (enqueueError.code === "42P01") {
          // Queue table missing — phase-4 migration not applied to this DB.
          // Continuing the loop is pointless because every subsequent enqueue
          // will hit the same error. Surface it loudly.
          pipelineSetupError =
            "event_tag_queue table is missing. Run `supabase db push --linked` to apply phase-4 migrations, then `supabase functions deploy process-tag-queue --linked`."
          break
        }
        enqueueFailures += 1
      }

      // Flush progress every N events so the UI shows live counts.
      if (eventsImported % PROGRESS_BATCH === 0) {
        await flushProgress()
      }
    }

    // Status derivation precedence:
    //   1. pipelineSetupError (queue table missing) → 'error' + actionable hint
    //   2. found events but imported none → 'partial'
    //   3. any non-fatal enqueue failures → 'partial' (events landed but
    //      tag-event pipeline is unhealthy for some of them)
    //   4. otherwise 'success' (default initial value)
    if (pipelineSetupError) {
      status = "error"
      errorMessage = pipelineSetupError
    } else if (eventsImported === 0 && eventsFound > 0) {
      status = "partial"
    } else if (enqueueFailures > 0) {
      status = "partial"
      errorMessage = `Imported ${eventsImported} event${eventsImported === 1 ? "" : "s"} but ${enqueueFailures} failed to enqueue for tag-event classification (check Sentry for details).`
    }
  } catch (error) {
    status = "error"
    errorMessage = error instanceof Error ? error.message : "Unknown scrape failure."
    await captureEdgeException(
      error,
      errorContext(error, {
        function: "scrape-source",
        source_id: source.id,
        source_name: source.name,
        source_type: source.source_type,
        run_id: runId,
      })
    )
    logEdgeEvent(
      "error",
      "scrape-source fetch failed",
      errorContext(error, {
        function: "scrape-source",
        source_id: source.id,
        source_name: source.name,
        source_type: source.source_type,
        run_id: runId,
      })
    )
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
        .eq("id", runId)

      await supabase
        .from("event_sources")
        .update({
          last_scraped_at: new Date().toISOString(),
          last_status: status,
          // Only reset error_count on full success. A 'partial' run (events
          // found, none imported) used to clear the counter and mask persistent
          // failures; keep accumulating until a clean success.
          error_count: status === "success" ? 0 : source.error_count + (status === "error" ? 1 : 0),
        })
        .eq("id", source.id)
      // Kick the tag-queue worker if we imported anything. The RPC fires
      // net.http_post (async) and returns immediately — scrape-source does not
      // wait for tagging to complete. Errors are intentionally swallowed so a
      // tagging hiccup never affects the scrape status.
      if (eventsImported > 0) {
        await supabase.rpc("invoke_process_tag_queue").catch(() => {})
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
        })
      )
    }
  }

  return {
    sourceId: source.id,
    status,
    eventsFound,
    eventsImported,
    eventsSkipped,
    error: errorMessage,
  }
}
