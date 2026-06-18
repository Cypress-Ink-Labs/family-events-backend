import type { SupabaseClient } from "@supabase/supabase-js"
import type { EventSourceRow } from "./types.ts"

export function isSourceDue(source: EventSourceRow): boolean {
  if (!source.last_scraped_at) {
    return true
  }

  const lastScraped = new Date(source.last_scraped_at).getTime()
  const elapsed = Date.now() - lastScraped
  return elapsed >= source.scrape_interval_hours * 60 * 60 * 1000
}

/**
 * Resolve the timezone for scraped events. Prefers the source's city timezone,
 * falls back to UTC so clocks stay correct even if cities table is incomplete.
 */
export async function resolveCityTimezone(
  supabase: SupabaseClient,
  cityId: string | null
): Promise<string> {
  if (!cityId) return "UTC"
  const { data } = await supabase.from("cities").select("timezone").eq("id", cityId).maybeSingle()
  return (data?.timezone as string | undefined) ?? "UTC"
}
