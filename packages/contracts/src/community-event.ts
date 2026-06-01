/**
 * Community event submission types and constants.
 */

export interface CommunityEventInput {
  title: string
  description?: string
  start_datetime: string
  end_datetime?: string | null
  venue_name?: string
  address?: string
  city_id: string
  age_min?: number | null
  age_max?: number | null
  is_free: boolean
  price?: number | null
}

/** Max community event submissions per user per 24-hour period. */
export const COMMUNITY_EVENT_DAILY_LIMIT = 5
