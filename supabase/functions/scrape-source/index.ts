import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "@supabase/supabase-js"
import { DOMParser } from "@b-fuze/deno-dom"

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

function parseIsoDate(value: string | null | undefined): string | null {
  if (!value) {
    return null
  }

  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) {
    return null
  }
  return parsed.toISOString()
}

function parseIcalDate(value: string | null): string | null {
  if (!value) {
    return null
  }

  const compact = value.trim()
  if (/^\d{8}$/.test(compact)) {
    const year = compact.slice(0, 4)
    const month = compact.slice(4, 6)
    const day = compact.slice(6, 8)
    return new Date(`${year}-${month}-${day}T00:00:00Z`).toISOString()
  }

  if (/^\d{8}T\d{6}Z$/.test(compact)) {
    const year = compact.slice(0, 4)
    const month = compact.slice(4, 6)
    const day = compact.slice(6, 8)
    const hour = compact.slice(9, 11)
    const minute = compact.slice(11, 13)
    const second = compact.slice(13, 15)
    return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`).toISOString()
  }

  if (/^\d{8}T\d{6}$/.test(compact)) {
    const year = compact.slice(0, 4)
    const month = compact.slice(4, 6)
    const day = compact.slice(6, 8)
    const hour = compact.slice(9, 11)
    const minute = compact.slice(11, 13)
    const second = compact.slice(13, 15)
    return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}`).toISOString()
  }

  return parseIsoDate(compact)
}

function decodeHtml(value: string): string {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
}

function stripHtml(value: string): string {
  return decodeHtml(value.replaceAll(/<[^>]*>/g, " "))
    .replaceAll(/\s+/g, " ")
    .trim()
}

function extractPrice(text: string): { price: number | null; isFree: boolean } {
  const lower = text.toLowerCase()

  const freePatterns = [
    /\bfree\b/,
    /\bno cost\b/,
    /\bno charge\b/,
    /\bcomplimentary\b/,
    /\bfree admission\b/,
    /\bfree event\b/,
  ]
  for (const pattern of freePatterns) {
    if (pattern.test(lower)) {
      return { price: null, isFree: true }
    }
  }

  const priceMatch = text.match(/\$\s*(\d+(?:\.\d{1,2})?)/)
  if (priceMatch) {
    return { price: Number(priceMatch[1]), isFree: false }
  }

  return { price: null, isFree: false }
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
        urls.add(resolved)
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

    const summary = eventBlock.match(/SUMMARY:(.+)/)?.[1]?.trim() ?? ""
    if (!summary) {
      continue
    }

    const description =
      eventBlock
        .match(/DESCRIPTION:(.+)/)?.[1]
        ?.replaceAll("\\n", " ")
        .trim() ?? ""
    const dtStartRaw = eventBlock.match(/DTSTART[^:]*:(.+)/)?.[1]?.trim() ?? null
    const dtEndRaw = eventBlock.match(/DTEND[^:]*:(.+)/)?.[1]?.trim() ?? null
    const location = eventBlock.match(/LOCATION:(.+)/)?.[1]?.trim() ?? null
    const url = eventBlock.match(/URL:(.+)/)?.[1]?.trim() ?? null

    const startDatetime = parseIcalDate(dtStartRaw)
    if (!startDatetime) {
      continue
    }

    const attachMatches = [...eventBlock.matchAll(/ATTACH[^:]*:(.+)/g)]
    const icalImages: string[] = []
    for (const m of attachMatches) {
      const val = m[1].trim()
      if (/^https?:\/\/.+\.(jpg|jpeg|png|gif|webp)/i.test(val)) {
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
          webImages.push(new URL(src, sourceUrl).toString())
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
}

async function fetchSourceEvents(source: EventSourceRow): Promise<ParsedEvent[]> {
  if (source.source_type === "manual") {
    return []
  }

  const response = await fetch(source.url, {
    headers: {
      "User-Agent": "family-events-ingester/1.0 (+https://family-events.local)",
      Accept: "text/html,application/xml,text/xml,*/*",
    },
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

  try {
    const parsedEvents = await fetchSourceEvents(source)
    eventsFound = parsedEvents.length

    for (const parsed of parsedEvents) {
      if (!parsed.title || !parsed.startDatetime) {
        eventsSkipped += 1
        continue
      }

      let existingEventId: string | null = null
      if (parsed.sourceUrl) {
        const { data: existing } = await supabase
          .from("events")
          .select("id")
          .eq("source_id", source.id)
          .eq("source_url", parsed.sourceUrl)
          .maybeSingle()
        existingEventId = existing?.id ?? null
      }

      const payload = {
        title: parsed.title,
        description: parsed.description || null,
        start_datetime: parsed.startDatetime,
        end_datetime: parsed.endDatetime,
        timezone: "America/New_York",
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
    }

    if (eventsImported === 0 && eventsFound > 0) {
      status = "partial"
    }
  } catch (error) {
    status = "error"
    errorMessage = error instanceof Error ? error.message : "Unknown scrape failure."
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

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    const supabase = createClient(supabaseUrl, serviceRoleKey)

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
