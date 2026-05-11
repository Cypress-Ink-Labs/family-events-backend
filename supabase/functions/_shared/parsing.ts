// Pure parsing helpers for scrape-source. No Deno imports — safe to import from
// Vitest (Node) tests as well as the edge function (Deno runtime).

export function parseIsoDate(value: string | null | undefined): string | null {
  if (!value) {
    return null
  }

  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) {
    return null
  }
  return parsed.toISOString()
}

export function parseIcalDate(value: string | null): string | null {
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
    // Treat timezone-less iCal as UTC for consistent behaviour across server environments
    return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`).toISOString()
  }

  return parseIsoDate(compact)
}

export function decodeHtml(value: string): string {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(parseInt(dec, 10)))
}

/**
 * Unescape iCal (RFC 5545 §3.3.11) text values: \n, \N → newline, \, → comma,
 * \; → semicolon, \\ → backslash. Leaves other sequences as-is.
 */
export function unescapeIcalText(value: string): string {
  return value
    .replace(/\\n/gi, " ")
    .replace(/\\,/g, ",")
    .replace(/\\;/g, ";")
    .replace(/\\\\/g, "\\")
}

export function stripHtml(value: string): string {
  return decodeHtml(value.replaceAll(/<[^>]*>/g, " "))
    .replaceAll(/\s+/g, " ")
    .trim()
}

export function extractPrice(text: string): { price: number | null; isFree: boolean } {
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

/**
 * Build a dedup key for cross-source event detection.
 * Same title + same start minute + same city = same event regardless of source.
 */
export function dedupKey(title: string, startDatetime: string, cityId: string | null): string {
  const normalizedTitle = title.trim().toLowerCase()
  // Truncate to minute precision to handle minor ISO format variations
  const minute = startDatetime.slice(0, 16)
  return `${cityId ?? "null"}::${minute}::${normalizedTitle}`
}
