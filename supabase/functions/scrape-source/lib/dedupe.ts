import type { SupabaseClient } from "@supabase/supabase-js"
import { dedupKey } from "../../_shared/parsing.ts"
import type { EventSourceRow, ExistingEventIndex, ParsedEvent } from "./types.ts"

/**
 * Fetch existing events relevant to this scrape run in ONE query instead of
 * N queries. Covers both within-source (source_url match) and cross-source
 * (title + start + city match) deduplication.
 */
export async function buildExistingEventIndex(
  supabase: SupabaseClient,
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
