import type { SupabaseClient } from "@supabase/supabase-js"
import type { EventSourceRow, ExistingEventIndex, ParsedEvent } from "./types.ts"

// buildExistingEventIndex is superseded by bulk_import_scrape_events RPC
// (migration 20260601007000). The RPC handles within-source dedup via
// UNIQUE(source_id, source_url). Cross-source dedup runs as a separate
// periodic job — it was O(N×events) per call with a LATERAL full scan.
export async function buildExistingEventIndex(
  supabase: SupabaseClient,
  source: EventSourceRow,
  _parsedEvents: ParsedEvent[]
): Promise<ExistingEventIndex> {
  const bySourceUrl = new Map<string, string>()
  const byDedupKey = new Map<string, string>()

  const { data: rows } = await supabase
    .from("events")
    .select("id, source_url")
    .eq("source_id", source.id)

  for (const row of (rows ?? []) as Array<{ id: string; source_url: string | null }>) {
    if (row.source_url) {
      bySourceUrl.set(row.source_url, row.id)
    }
  }

  return { bySourceUrl, byDedupKey }
}
