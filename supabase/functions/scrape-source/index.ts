import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "@supabase/supabase-js"
import { DOMParser } from "@b-fuze/deno-dom"
import { requireAdminOrService } from "../_shared/auth.ts"
import {
  decodeHtml,
  dedupKey,
  extractPrice,
  parseIcalDate,
  parseIsoDate,
  stripHtml,
  unescapeIcalText,
} from "../_shared/parsing.ts"
import { validateExternalUrl } from "../_shared/url-validation.ts"

const SOURCE_FETCH_TIMEOUT_MS = 10_000

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
}

type SourceType = "website" | "ical" | "rss" | "manual"
type RunStatus = "running" | "success" | "error" | "partial"

interface EventSourceRow {
  id: string
  name: string
  url: string
  source_type: SourceType
  city_id: string | null
  is_active: boolean
  scrape_interval_hours: number
  last_scraped_at: string | null
  last_status: "pending" | "success" | "error" | "partial" | null
  error_count: number
}

interface ParsedEvent {
  title: string
  description: string
  startDatetime: string
  endDatetime: string | null
  venueName: string | null
  address: string | null
  sourceUrl: string | null
  imageUrl: string | null
  images: string[]
  price: number | null
  isFree: boolean
}

interface SourceResult {
  sourceId: string
  status: RunStatus
  eventsFound: number
  eventsImported: number
  eventsSkipped: number
  error: string | null
}

function extractImages(rawContent: string, baseUrl: string): string[] {
  const urls = new Set<string>()

  const patterns = [
    /<media:content[^>]+url=["']([^"']+)["'][^>]*\/?>/gi,
    /<media:thumbnail[^>]+url=["']([^"']+)["'][^>]*\/?>/gi,
    /<enclosure[^>]+url=["']([^"']+)["'][^>]+type=["']image\/[^"']+["'][^>]*\/?>/gi,
    /<enclosure[^>]+type=["']image\/[^"']+["'][^>]+url=["']([^"']+)["'][^>]*\/?>/gi,
    /<img[^>]+src=["']([^"']+)["'][^>]*\/?>/gi,
  ]

  for (const pattern of patterns) {
    for (const match of rawContent.matchAll(pattern)) {
      try {
        const resolved = new URL(match[1], baseUrl).toString()
        if (validateExternalUrl(resolved).ok) {
          urls.add(resolved)
        }
      } catch {
        // skip invalid URLs
      }
    }
  }

  return [...urls].slice(0, 5)
}

function parseRssFeed(xml: string, sourceUrl: string): ParsedEvent[] {
  const itemMatches = [
    ...xml.matchAll(/<item[\s\S]*?<\/item>/gi),
    ...xml.matchAll(/<entry[\s\S]*?<\/entry>/gi),
  ]
  const results: ParsedEvent[] = []

  for (const [rawItem] of itemMatches) {
    const titleMatch =
      rawItem.match(/<title><!\[CDATA\[([\s\S]*?)\]\]><\/title>/i) ??
      rawItem.match(/<title>([\s\S]*?)<\/title>/i)
    const title = titleMatch ? stripHtml(titleMatch[1]) : ""
    if (!title) {
      continue
    }

    const descriptionMatch =
      rawItem.match(/<description><!\[CDATA\[([\s\S]*?)\]\]><\/description>/i) ??
      rawItem.match(/<description>([\s\S]*?)<\/description>/i) ??
      rawItem.match(/<summary>([\s\S]*?)<\/summary>/i)
    const description = descriptionMatch ? stripHtml(descriptionMatch[1]) : ""

    const linkMatch =
      rawItem.match(/<link>([\s\S]*?)<\/link>/i) ??
      rawItem.match(/<link[^>]*href=["']([^"']+)["'][^>]*\/?>/i)
    const sourceLink = linkMatch ? decodeHtml(linkMatch[1].trim()) : sourceUrl
    const normalizedSourceLink = sourceLink ? new URL(sourceLink, sourceUrl).toString() : null

    const dateMatch =
      rawItem.match(/<pubDate>([\s\S]*?)<\/pubDate>/i) ??
      rawItem.match(/<updated>([\s\S]*?)<\/updated>/i) ??
      rawItem.match(/<dc:date>([\s\S]*?)<\/dc:date>/i)
    const startDatetime = parseIsoDate(dateMatch?.[1]?.trim()) ?? new Date().toISOString()

    const images = extractImages(rawItem, sourceUrl)
    const rawDescription = descriptionMatch?.[1] ?? ""
    const priceInfo = extractPrice(rawDescription)

    results.push({
      title,
      description,
      startDatetime,
      endDatetime: null,
      venueName: null,
      address: null,
      sourceUrl: normalizedSourceLink,
      imageUrl: images[0] ?? null,
      images,
      price: priceInfo.price,
      isFree: priceInfo.isFree,
    })
  }

  return results
}

function parseIcalFeed(icalContent: string): ParsedEvent[] {
  const blocks = icalContent.split("BEGIN:VEVENT").slice(1)
  const events: ParsedEvent[] = []

  for (const block of blocks) {
    const eventBlock = block.split("END:VEVENT")[0]
    if (!eventBlock) {
      continue
    }

    const rawSummary = eventBlock.match(/SUMMARY:(.+)/)?.[1]?.trim() ?? ""
    const summary = unescapeIcalText(rawSummary)
    if (!summary) {
      continue
    }

    const rawDescription = eventBlock.match(/DESCRIPTION:(.+)/)?.[1]?.trim() ?? ""
    const description = unescapeIcalText(rawDescription)
    const dtStartRaw = eventBlock.match(/DTSTART[^:]*:(.+)/)?.[1]?.trim() ?? null
    const dtEndRaw = eventBlock.match(/DTEND[^:]*:(.+)/)?.[1]?.trim() ?? null
    const rawLocation = eventBlock.match(/LOCATION:(.+)/)?.[1]?.trim() ?? null
    const location = rawLocation ? unescapeIcalText(rawLocation) : null
    const url = eventBlock.match(/URL:(.+)/)?.[1]?.trim() ?? null

    const startDatetime = parseIcalDate(dtStartRaw)
    if (!startDatetime) {
      continue
    }

    const attachMatches = [...eventBlock.matchAll(/ATTACH[^:]*:(.+)/g)]
    const icalImages: string[] = []
    for (const m of attachMatches) {
      const val = m[1].trim()
      if (
        /^https?:\/\/.+\.(jpg|jpeg|png|gif|webp)/i.test(val) &&
        validateExternalUrl(val).ok
      ) {
        icalImages.push(val)
      }
    }

    const priceInfo = extractPrice(description)

    events.push({
      title: summary,
      description,
      startDatetime,
      endDatetime: parseIcalDate(dtEndRaw),
      venueName: location,
      address: location,
      sourceUrl: url,
      imageUrl: icalImages[0] ?? null,
      images: icalImages.slice(0, 5),
      price: priceInfo.price,
      isFree: priceInfo.isFree,
    })
  }

  return events
}

function parseDateFromText(value: string): string | null {
  const datePattern =
    /\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?\b/i

  const match = value.match(datePattern)
  if (!match) {
    return null
  }

  const parsed = new Date(match[0])
  if (Number.isNaN(parsed.getTime())) {
    return null
  }
  return parsed.toISOString()
}

function parseWebsite(html: string, sourceUrl: string): ParsedEvent[] {
  const parser = new DOMParser()
  const doc = parser.parseFromString(html, "text/html")
  if (!doc) {
    return []
  }

  const links = [...doc.querySelectorAll("a[href]")].slice(0, 80)
  const seenTitles = new Set<string>()
  const events: ParsedEvent[] = []

  for (const link of links) {
    const title = link.textContent?.replaceAll(/\s+/g, " ").trim() ?? ""
    if (!title || title.length < 8 || seenTitles.has(title.toLowerCase())) {
      continue
    }

    const href = link.getAttribute("href")
    const normalizedUrl = href ? new URL(href, sourceUrl).toString() : sourceUrl
    const surroundingText = link.parentElement?.textContent?.replaceAll(/\s+/g, " ").trim() ?? title
    const startDatetime = parseDateFromText(surroundingText) ?? new Date().toISOString()

    // Find nearest image in parent/ancestor elements
    const webImages: string[] = []
    const container = link.parentElement?.parentElement ?? link.parentElement
    const imgEl = container?.querySelector("img")
    if (imgEl) {
      const src = imgEl.getAttribute("src")
      if (src) {
        try {
          const resolved = new URL(src, sourceUrl).toString()
          if (validateExternalUrl(resolved).ok) {
            webImages.push(resolved)
          }
        } catch {
          // skip invalid URLs
        }
      }
    }

    const priceInfo = extractPrice(surroundingText)

    seenTitles.add(title.toLowerCase())
    events.push({
      title,
      description: surroundingText.slice(0, 500),
      startDatetime,
      endDatetime: null,
      venueName: null,
      address: null,
      sourceUrl: normalizedUrl,
      imageUrl: webImages[0] ?? null,
      images: webImages,
      price: priceInfo.price,
      isFree: priceInfo.isFree,
    })
  }

  return events
}

function isSourceDue(source: EventSourceRow): boolean {
  if (!source.last_scraped_at) {
    return true
  }

  const lastScraped = new Date(source.last_scraped_at).getTime()
  const elapsed = Date.now() - lastScraped
  return elapsed >= source.scrape_interval_hours * 60 * 60 * 1000
}

async function tagImportedEvent(
  supabaseUrl: string,
  serviceRoleKey: string,
  eventId: string,
  title: string,
  description: string
) {
  try {
    await fetch(`${supabaseUrl}/functions/v1/tag-event`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({
        event_id: eventId,
        title,
        description,
      }),
    })
  } catch (err) {
    console.error("tag-event invocation failed", { eventId, err: String(err) })
  }
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

/**
 * Resolve the timezone for scraped events. Prefers the source's city timezone,
 * falls back to UTC so clocks stay correct even if cities table is incomplete.
 */
async function resolveCityTimezone(
  supabase: ReturnType<typeof createClient>,
  cityId: string | null
): Promise<string> {
  if (!cityId) return "UTC"
  const { data } = await supabase.from("cities").select("timezone").eq("id", cityId).maybeSingle()
  return (data?.timezone as string | undefined) ?? "UTC"
}

interface ExistingEventIndex {
  bySourceUrl: Map<string, string> // source_url -> event_id (within this source)
  byDedupKey: Map<string, string> // dedup_key -> event_id (cross-source, same city)
}

/**
 * Fetch existing events relevant to this scrape run in ONE query instead of
 * N queries. Covers both within-source (source_url match) and cross-source
 * (title + start + city match) deduplication.
 */
async function buildExistingEventIndex(
  supabase: ReturnType<typeof createClient>,
  source: EventSourceRow,
  parsedEvents: ParsedEvent[]
): Promise<ExistingEventIndex> {
  const bySourceUrl = new Map<string, string>()
  const byDedupKey = new Map<string, string>()

  if (parsedEvents.length === 0) {
    return { bySourceUrl, byDedupKey }
  }

  // Within-source index: any prior event from THIS source
  const { data: sameSourceRows } = await supabase
    .from("events")
    .select("id, source_url, title, start_datetime, city_id")
    .eq("source_id", source.id)

  for (const row of (sameSourceRows ?? []) as Array<{
    id: string
    source_url: string | null
    title: string
    start_datetime: string
    city_id: string | null
  }>) {
    if (row.source_url) {
      bySourceUrl.set(row.source_url, row.id)
    }
    byDedupKey.set(dedupKey(row.title, row.start_datetime, row.city_id), row.id)
  }

  // Cross-source index: events in same city from OTHER sources that might match
  // our parsed events by title + start datetime.
  if (source.city_id) {
    // Collect candidate start datetimes to narrow the cross-source query
    const starts = parsedEvents.map((e) => e.startDatetime)
    if (starts.length > 0) {
      const minStart = starts.reduce((a, b) => (a < b ? a : b))
      const maxStart = starts.reduce((a, b) => (a > b ? a : b))

      const { data: crossSourceRows } = await supabase
        .from("events")
        .select("id, title, start_datetime, city_id")
        .eq("city_id", source.city_id)
        .neq("source_id", source.id)
        .gte("start_datetime", minStart)
        .lte("start_datetime", maxStart)

      for (const row of (crossSourceRows ?? []) as Array<{
        id: string
        title: string
        start_datetime: string
        city_id: string | null
      }>) {
        const key = dedupKey(row.title, row.start_datetime, row.city_id)
        if (!byDedupKey.has(key)) {
          byDedupKey.set(key, row.id)
        }
      }
    }
  }

  return { bySourceUrl, byDedupKey }
}

async function processSource(
  supabase: ReturnType<typeof createClient>,
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
      .eq("id", runRow.id)
  }

  try {
    const parsedEvents = await fetchSourceEvents(source)
    eventsFound = parsedEvents.length

    // Write total found immediately so the UI shows "X found" while import runs.
    await flushProgress()

    const timezone = await resolveCityTimezone(supabase, source.city_id)
    const index = await buildExistingEventIndex(supabase, source, parsedEvents)

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
        images: parsed.images.length > 0 ? parsed.images : parsed.imageUrl ? [parsed.imageUrl] : [],
        price: parsed.price,
        is_free: parsed.isFree,
        status: "draft" as const,
      }

      const operation = existingEventId
        ? supabase.from("events").update(payload).eq("id", existingEventId).select("id").single()
        : supabase.from("events").insert(payload).select("id").single()

      const { data: upsertedEvent, error: upsertError } = await operation
      if (upsertError || !upsertedEvent) {
        eventsSkipped += 1
        continue
      }

      eventsImported += 1

      await tagImportedEvent(
        supabaseUrl,
        serviceRoleKey,
        upsertedEvent.id,
        parsed.title,
        parsed.description
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
    console.error("scrape-source fetch failed", {
      source_id: source.id,
      source_name: source.name,
      source_type: source.source_type,
      error: errorMessage,
    })
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
    .eq("id", runRow.id)

  await supabase
    .from("event_sources")
    .update({
      last_scraped_at: new Date().toISOString(),
      last_status: status === "running" ? "pending" : status,
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? ""
  const supabase = createClient(supabaseUrl, serviceRoleKey)

  // Auth: accept service role (cron) or admin user JWT. Reject everything else.
  const auth = await requireAdminOrService(req, supabase, supabaseUrl, serviceRoleKey, anonKey)
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  try {
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {}
    const requestedSourceId = typeof body?.source_id === "string" ? body.source_id : null

    let sourceQuery = supabase.from("event_sources").select("*").eq("is_active", true)
    if (requestedSourceId) {
      sourceQuery = sourceQuery.eq("id", requestedSourceId)
    }

    const { data: sourcesRaw, error: sourceError } = await sourceQuery
    if (sourceError) {
      throw sourceError
    }

    const sources = (sourcesRaw ?? []) as EventSourceRow[]
    const dueSources = requestedSourceId ? sources : sources.filter(isSourceDue)
    const results: SourceResult[] = []

    for (const source of dueSources) {
      const result = await processSource(supabase, source, supabaseUrl, serviceRoleKey)
      results.push(result)
    }

    return new Response(
      JSON.stringify({
        processed_sources: results.length,
        results,
      }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    )
  } catch (error) {
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : "Unexpected scrape failure.",
      }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    )
  }
})
