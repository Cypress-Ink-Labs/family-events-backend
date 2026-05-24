// Unsplash search client — looks up a landscape photo by tag slug for
// events that landed with empty `events.images`.
//
// Why this exists: scraper sources frequently strip image URLs (hot-link
// blocking, robots policies, login-walled CDN). Without a fallback, every
// affected card on web / iOS / Android renders a generic picsum.photos
// placeholder that doesn't match the event. Unsplash returns a real photo
// keyed by the tag we already classified the event with, which keeps the
// "warm editorial bulletin board" DESIGN.md aesthetic intact.
//
// API guidelines (https://unsplash.com/documentation):
//   - Authenticate with Client-ID <UNSPLASH_ACCESS_KEY>.
//   - Use the orientation=landscape filter for card-shaped photos.
//   - Trigger the download-tracking endpoint when a photo is "used" (i.e.
//     persisted into our DB). This is a no-rate-limit GET and is required
//     to stay in the developer tier.
//   - Surface "Some event photos courtesy of Unsplash" credit somewhere
//     reachable (single app-wide credit line; per-photo attribution is
//     requested "where reasonable" but not legally required).
//
// Rate limit: 5000 req/hr on the demo tier. At our cron cadence (~25
// events / 15 min = 2400/day) we stay comfortably under.

interface UnsplashSearchHit {
  urls?: {
    regular?: string
  }
  links?: {
    download_location?: string
  }
}

interface UnsplashSearchResponse {
  results?: UnsplashSearchHit[]
}

export interface UnsplashResult {
  url: string
  /** Tag we matched on (for logging). */
  matchedTag: string
}

const SEARCH_ENDPOINT = "https://api.unsplash.com/search/photos"

/**
 * Resolve a single Unsplash image URL for an event given its tag slugs.
 *
 * Walks tags in order (callers pass tags ordered by confidence DESC) and
 * stops at the first tag that yields a search result. Returns `null` when
 * the access key is missing, when every tag misses, or on any network /
 * parse error — the caller treats this as "leave images empty, next tick
 * will retry."
 */
export async function findFallbackImage(
  tags: string[],
  accessKey: string,
  options: { fetchImpl?: typeof fetch } = {},
): Promise<UnsplashResult | null> {
  if (!accessKey) return null
  if (tags.length === 0) return null

  const fetcher = options.fetchImpl ?? fetch

  for (const rawTag of tags) {
    const tag = rawTag.trim()
    if (!tag) continue

    const query = `${tag} family`
    const url = `${SEARCH_ENDPOINT}?query=${encodeURIComponent(query)}&orientation=landscape&per_page=1&content_filter=high`

    try {
      const res = await fetcher(url, {
        headers: {
          Authorization: `Client-ID ${accessKey}`,
          "Accept-Version": "v1",
        },
        signal: AbortSignal.timeout(5_000),
      })
      if (!res.ok) continue

      const body = (await res.json()) as UnsplashSearchResponse
      const hit = body.results?.[0]
      const photoUrl = hit?.urls?.regular
      if (!photoUrl) continue

      // Best-effort download tracking. Fire-and-forget — failure here
      // does not block the photo from being persisted. The 200 we
      // already got from /search/photos satisfies the API quota
      // accounting; tracking is for Unsplash's photographer analytics.
      const trackingURL = hit.links?.download_location
      if (trackingURL) {
        void fetcher(trackingURL, {
          headers: {
            Authorization: `Client-ID ${accessKey}`,
            "Accept-Version": "v1",
          },
          signal: AbortSignal.timeout(3_000),
        }).catch(() => {})
      }

      return { url: photoUrl, matchedTag: tag }
    } catch {
      // Network / timeout / parse failure: try the next tag, then bail.
      continue
    }
  }
  return null
}
