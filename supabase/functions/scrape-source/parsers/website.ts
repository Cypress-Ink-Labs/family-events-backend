import { DOMParser } from "@b-fuze/deno-dom"
import { extractPrice, parseIsoDate } from "../../_shared/parsing.ts"
import { validateExternalUrl } from "../../_shared/url-validation.ts"
import type { ParsedEvent } from "../lib/types.ts"

function toArray(value: unknown): unknown[] {
  if (Array.isArray(value)) {
    return value
  }
  return value === null || value === undefined ? [] : [value]
}

function eventNodes(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) {
    return value.flatMap((item) => eventNodes(item))
  }
  if (!value || typeof value !== "object") {
    return []
  }

  const node = value as Record<string, unknown>
  const typeValues = toArray(node["@type"]).map((entry) => String(entry).toLowerCase())
  const isEvent = typeValues.some((entry) => entry === "event" || entry.endsWith(":event"))
  const graphEvents = eventNodes(node["@graph"])
  return isEvent ? [node, ...graphEvents] : graphEvents
}

function pickText(value: unknown): string | null {
  if (typeof value === "string") {
    const trimmed = value.trim()
    return trimmed.length > 0 ? trimmed : null
  }
  if (value && typeof value === "object") {
    const node = value as Record<string, unknown>
    return pickText(node["@value"] ?? node.name ?? node.text)
  }
  return null
}

function extractImageUrls(value: unknown): string[] {
  if (typeof value === "string") {
    return [value]
  }
  if (Array.isArray(value)) {
    return value.flatMap((entry) => extractImageUrls(entry))
  }
  if (value && typeof value === "object") {
    const node = value as Record<string, unknown>
    return extractImageUrls(node.url ?? node.contentUrl)
  }
  return []
}

function normalizeUrl(value: string | null, baseUrl: string): string | null {
  if (!value) {
    return null
  }
  try {
    return new URL(value, baseUrl).toString()
  } catch {
    return null
  }
}

export function parseWebsite(html: string, sourceUrl: string): ParsedEvent[] {
  const parser = new DOMParser()
  const doc = parser.parseFromString(html, "text/html")
  if (!doc) {
    return []
  }

  const eventCandidates: Record<string, unknown>[] = []
  for (const script of doc.querySelectorAll('script[type="application/ld+json"]')) {
    const rawJson = script.textContent?.trim() ?? ""
    if (!rawJson) {
      continue
    }

    try {
      const parsed = JSON.parse(rawJson)
      eventCandidates.push(...eventNodes(parsed))
    } catch {
      continue
    }
  }

  const seenKeys = new Set<string>()
  const events: ParsedEvent[] = []

  for (const candidate of eventCandidates) {
    const title = pickText(candidate.name)
    if (!title) {
      continue
    }

    const startDatetime = parseIsoDate(pickText(candidate.startDate))
    if (!startDatetime) {
      continue
    }

    const endDatetime = parseIsoDate(pickText(candidate.endDate))
    const description = pickText(candidate.description) ?? title
    const eventUrl = normalizeUrl(pickText(candidate.url), sourceUrl) ?? sourceUrl
    const venueName =
      pickText((candidate.location as Record<string, unknown> | undefined)?.name) ??
      pickText(candidate.location)
    const address =
      pickText((candidate.location as Record<string, unknown> | undefined)?.address) ??
      pickText((candidate.location as Record<string, unknown> | undefined)?.["streetAddress"]) ??
      venueName

    const key = `${title.toLowerCase()}::${startDatetime}`
    if (seenKeys.has(key)) {
      continue
    }

    const webImages: string[] = []
    for (const image of extractImageUrls(candidate.image)) {
      const normalized = normalizeUrl(image, sourceUrl)
      if (normalized && validateExternalUrl(normalized).ok && !webImages.includes(normalized)) {
        webImages.push(normalized)
      }
      if (webImages.length >= 5) {
        break
      }
    }

    const offers = candidate.offers as Record<string, unknown> | undefined
    const priceFromOffers = typeof offers?.price === "number" ? offers.price : null
    const isFreeFromOffers = priceFromOffers === 0
    const priceInfo = extractPrice(description)

    seenKeys.add(key)
    events.push({
      title,
      description: description.slice(0, 500),
      startDatetime,
      endDatetime,
      venueName,
      address,
      sourceUrl: eventUrl,
      imageUrl: webImages[0] ?? null,
      images: webImages,
      price: priceFromOffers ?? priceInfo.price,
      isFree: isFreeFromOffers || priceInfo.isFree,
    })
  }

  return events
}
