// Nominatim geocoder — free, no API key, 1 req/sec rate limit per their policy.
// https://operations.osmfoundation.org/policies/nominatim/
//
// Usage: always pass a descriptive User-Agent (contact info ideal for production).
// For local/private dev a generic identifier is fine.

export interface GeocodeResult {
  latitude: number
  longitude: number
  source: "nominatim" | "city-fallback"
}

interface NominatimHit {
  lat: string
  lon: string
}

const NOMINATIM_UA = "family-events-ui/1.0 (geocoder)"

/**
 * Query Nominatim for a place. Returns lat/lng or null if not found / error.
 * Caller must respect the 1 req/sec rate limit.
 */
export async function geocodeViaNominatim(query: string): Promise<GeocodeResult | null> {
  if (!query || query.trim().length < 3) return null

  const url = `https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(query)}`

  try {
    const res = await fetch(url, {
      headers: {
        "User-Agent": NOMINATIM_UA,
        Accept: "application/json",
      },
    })
    if (!res.ok) return null

    const hits = (await res.json()) as NominatimHit[]
    const first = hits?.[0]
    if (!first) return null

    const lat = Number(first.lat)
    const lng = Number(first.lon)
    if (Number.isNaN(lat) || Number.isNaN(lng)) return null

    return { latitude: lat, longitude: lng, source: "nominatim" }
  } catch {
    return null
  }
}

/**
 * Build a geocoding query string from event metadata. Prefers address, then venue
 * name, always scoped by city to avoid matching a same-named place elsewhere.
 */
export function buildGeocodeQuery(parts: {
  address: string | null
  venueName: string | null
  cityName: string | null
  cityState: string | null
}): string | null {
  const base = parts.address?.trim() || parts.venueName?.trim()
  if (!base) return null

  const locality = [parts.cityName, parts.cityState].filter(Boolean).join(", ")
  return locality ? `${base}, ${locality}` : base
}
