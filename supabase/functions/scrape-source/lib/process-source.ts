import type { SupabaseClient } from "@supabase/supabase-js"
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
