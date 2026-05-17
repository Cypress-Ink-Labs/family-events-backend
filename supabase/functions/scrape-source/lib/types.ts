import type { SourceType } from "../parsers/index.ts"

export type { SourceType }
export type RunStatus = "running" | "success" | "error" | "partial"

export interface EventSourceRow {
  id: string
  name: string
  url: string
  source_type: SourceType
  city_id: string | null
  is_active: boolean
  auto_approve: boolean
  scrape_interval_hours: number
  last_scraped_at: string | null
  last_status: "pending" | "success" | "error" | "partial" | null
  error_count: number
  date_window_days: number | null
}

export interface ParsedEvent {
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

export interface SourceResult {
  sourceId: string
  status: RunStatus
  eventsFound: number
  eventsImported: number
  eventsSkipped: number
  error: string | null
}

export interface ExistingEventIndex {
  bySourceUrl: Map<string, string>
  byDedupKey: Map<string, string>
}
