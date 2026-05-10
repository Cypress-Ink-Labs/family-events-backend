import type { SupabaseClient } from "@supabase/supabase-js"
import { captureEdgeException } from "../../_shared/sentry.ts"
import { errorContext, logEdgeEvent } from "../../_shared/logger.ts"
import { buildGeocodeQuery, geocodeViaNominatim } from "../../_shared/geocode.ts"
import { dedupKey } from "../../_shared/parsing.ts"
import { validateExternalUrl } from "../../_shared/url-validation.ts"
import { parseIcalFeed } from "../parsers/ical.ts"
import { parseRssFeed } from "../parsers/rss.ts"
import { parseWebsite } from "../parsers/website.ts"
import { buildExistingEventIndex } from "./dedupe.ts"
import { resolveCityTimezone } from "./schedule.ts"
import { tagImportedEvent } from "./tag-fanout.ts"
import type { EventSourceRow, ParsedEvent, RunStatus, SourceResult } from "./types.ts"

const SOURCE_FETCH_TIMEOUT_MS = 10_000
const IMAGE_HEAD_TIMEOUT_MS = 5_000
const IMAGE_MAX_BYTES = 2 * 1024 * 1024
const MAX_IMAGES_PER_EVENT = 5
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
  for (const imageCandidate of imageCandidates) {
    if (validImages.length >= MAX_IMAGES_PER_EVENT) {
      break
    }
    const validatedImage = await validateImageAtIngest(imageCandidate, allowedHosts)
    if (validatedImage && !validImages.includes(validatedImage)) {
      validImages.push(validatedImage)
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

async function fetchSourceEvents(source: EventSourceRow): Promise<ParsedEvent[]> {
  if (source.source_type === "manual") {
    return []
  }

  const validation = validateExternalUrl(source.url)
  if (!validation.ok) {
    throw new Error(`Source URL rejected by validator: ${validation.reason}`)
  }

  const response = await fetch(source.url, {
    headers: {
      "User-Agent": "family-events-ingester/1.0 (+https://family-events.local)",
      Accept: "text/html,application/xml,text/xml,*/*",
    },
    signal: AbortSignal.timeout(SOURCE_FETCH_TIMEOUT_MS),
  })

  if (!response.ok) {
    throw new Error(`Failed to fetch source (${response.status})`)
  }

  const content = await response.text()
  if (source.source_type === "rss") {
    return parseRssFeed(content, source.url)
  }
  if (source.source_type === "ical") {
    return parseIcalFeed(content)
  }
  return parseWebsite(content, source.url)
}

export async function processSource(
  supabase: SupabaseClient,
  source: EventSourceRow,
  supabaseUrl: string,
  serviceRoleKey: string
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
    const parsedEvents = await fetchSourceEvents(source)
    eventsFound = parsedEvents.length

    // Write total found immediately so the UI shows "X found" while import runs.
    await flushProgress()

    const timezone = await resolveCityTimezone(supabase, source.city_id)
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
        status: "draft" as const,
        ...(existingEventId
          ? {}
          : {
              latitude: geocodedCoordinates.latitude,
              longitude: geocodedCoordinates.longitude,
            }),
      }

      const operation = existingEventId
        ? supabase.from("events").update(payload).eq("id", existingEventId).select("id").single()
        : supabase.from("events").insert(payload).select("id").single()

      const { data: upsertedEvent, error: upsertError } = await operation
      if (upsertError || !upsertedEvent) {
        const error = upsertError ?? new Error("Event upsert returned no row.")
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

      await tagImportedEvent(
        supabaseUrl,
        serviceRoleKey,
        upsertedEvent.id,
        parsed.title,
        parsed.description,
        runRow.id
      )

      // Flush progress every N events so the UI shows live counts.
      if (eventsImported % PROGRESS_BATCH === 0) {
        await flushProgress()
      }
    }

    if (eventsImported === 0 && eventsFound > 0) {
      status = "partial"
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
  }

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
      error_count: status === "error" ? source.error_count + 1 : 0,
    })
    .eq("id", source.id)

  return {
    sourceId: source.id,
    status,
    eventsFound,
    eventsImported,
    eventsSkipped,
    error: errorMessage,
  }
}
