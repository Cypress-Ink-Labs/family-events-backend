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
//     persisted into our DB). Tracking is awaited by the caller after the
//     DB write so failures can be retried from persisted attribution rows.
//   - Surface per-photo attribution: "Photo by <photographer> on Unsplash".
//
// Rate limit: 5000 req/hr on the demo tier. At our cron cadence (~25
// events / 15 min = 2400/day) we stay comfortably under.

interface UnsplashSearchHit {
  id?: string
  urls?: {
    regular?: string
  }
  links?: {
    html?: string
    download_location?: string
  }
  user?: {
    name?: string
    username?: string
    links?: {
      html?: string
    }
  }
}

interface UnsplashSearchResponse {
  results?: UnsplashSearchHit[]
}

export interface UnsplashAttributionMetadata {
  photoId: string
  photographerName: string
  photographerUsername: string
  photographerProfileUrl: string
  photoUrl: string
  downloadLocation: string
}

export interface UnsplashResult {
  url: string
  /** Tag we matched on (for logging). */
  matchedTag: string
  attribution: UnsplashAttributionMetadata
}

export interface UnsplashTrackingResult {
  ok: boolean
  error: string | null
}

const SEARCH_ENDPOINT = "https://api.unsplash.com/search/photos"
const PHOTOS_ENDPOINT = "https://api.unsplash.com/photos"

function unsplashPhotoIdFromCdnUrl(imageUrl: string): string | null {
  try {
    const { hostname, pathname } = new URL(imageUrl)
    if (!hostname.includes("unsplash.com")) return null
    const match = pathname.match(/\/(photo-[\w-]+)/)
    return match?.[1] ?? null
  } catch {
    return null
  }
}

function firstString(...values: Array<string | undefined>): string | null {
  for (const value of values) {
    const trimmed = value?.trim()
    if (trimmed) return trimmed
  }
  return null
}

function attributionFromHit(hit: UnsplashSearchHit): UnsplashAttributionMetadata | null {
  const photoId = firstString(hit.id)
  const photographerUsername = firstString(hit.user?.username)
  const photographerName = firstString(hit.user?.name, photographerUsername ?? undefined)
  const photographerProfileUrl = firstString(hit.user?.links?.html)
  const photoUrl = firstString(hit.links?.html)
  const downloadLocation = firstString(hit.links?.download_location)

  if (
    !photoId ||
    !photographerName ||
    !photographerUsername ||
    !photographerProfileUrl ||
    !photoUrl ||
    !downloadLocation
  ) {
    return null
  }

  return {
    photoId,
    photographerName,
    photographerUsername,
    photographerProfileUrl,
    photoUrl,
    downloadLocation,
  }
}

export async function trackUnsplashDownload(
  downloadLocation: string,
  accessKey: string,
  options: { fetchImpl?: typeof fetch } = {},
): Promise<UnsplashTrackingResult> {
  if (!accessKey) return { ok: false, error: "UNSPLASH_ACCESS_KEY is not configured" }
  if (!downloadLocation.trim()) return { ok: false, error: "download location is empty" }

  const fetcher = options.fetchImpl ?? fetch

  try {
    const res = await fetcher(downloadLocation, {
      headers: {
        Authorization: `Client-ID ${accessKey}`,
        "Accept-Version": "v1",
      },
      signal: AbortSignal.timeout(3_000),
    })
    if (!res.ok) return { ok: false, error: `Unsplash tracking failed with HTTP ${res.status}` }
    return { ok: true, error: null }
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : String(err) }
  }
}

/**
 * Resolve a single Unsplash image URL for an event given its tag slugs.
 *
 * Walks tags in order (callers pass tags ordered by confidence DESC) and
 * stops at the first tag that yields a search result with complete attribution
 * metadata. Returns `null` when the access key is missing, when every tag
 * misses, or on any network / parse error — the caller treats this as "leave
 * images empty, next tick will retry."
 */
/**
 * Fetch attribution metadata for an existing Unsplash CDN image URL.
 * Extracts the CDN path slug (e.g. "photo-abc123") and calls GET /photos/:id.
 * Returns null on any failure — callers skip and retry next tick.
 */
export async function lookupUnsplashPhotoFromUrl(
  imageUrl: string,
  accessKey: string,
  options: { fetchImpl?: typeof fetch } = {},
): Promise<UnsplashAttributionMetadata | null> {
  if (!accessKey) return null
  const photoId = unsplashPhotoIdFromCdnUrl(imageUrl)
  if (!photoId) return null

  const fetcher = options.fetchImpl ?? fetch
  try {
    const res = await fetcher(`${PHOTOS_ENDPOINT}/${photoId}`, {
      headers: {
        Authorization: `Client-ID ${accessKey}`,
        "Accept-Version": "v1",
      },
      signal: AbortSignal.timeout(5_000),
    })
    if (!res.ok) return null
    const hit = (await res.json()) as UnsplashSearchHit
    return attributionFromHit(hit)
  } catch {
    return null
  }
}

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
      if (!hit || !photoUrl) continue

      const attribution = attributionFromHit(hit)
      if (!attribution) continue

      return { url: photoUrl, matchedTag: tag, attribution }
    } catch {
      // Network / timeout / parse failure: try the next tag, then bail.
      continue
    }
  }
  return null
}
