import { DOMParser } from "@b-fuze/deno-dom"
import { extractPrice } from "../../_shared/parsing.ts"
import { validateExternalUrl } from "../../_shared/url-validation.ts"
import { parseDateFromText } from "../lib/date.ts"
import type { ParsedEvent } from "../lib/types.ts"

export function parseWebsite(html: string, sourceUrl: string): ParsedEvent[] {
  const parser = new DOMParser()
  const doc = parser.parseFromString(html, "text/html")
  if (!doc) {
    return []
  }

  const links = [...doc.querySelectorAll("a[href]")].slice(0, 80)
  const seenTitles = new Set<string>()
  const events: ParsedEvent[] = []

  for (const link of links) {
    const title = link.textContent?.replaceAll(/\s+/g, " ").trim() ?? ""
    if (!title || title.length < 8 || seenTitles.has(title.toLowerCase())) {
      continue
    }

    const href = link.getAttribute("href")
    const normalizedUrl = href ? new URL(href, sourceUrl).toString() : sourceUrl
    const surroundingText = link.parentElement?.textContent?.replaceAll(/\s+/g, " ").trim() ?? title
    const startDatetime = parseDateFromText(surroundingText) ?? new Date().toISOString()

    // Find nearest image in parent/ancestor elements
    const webImages: string[] = []
    const container = link.parentElement?.parentElement ?? link.parentElement
    const imgEl = container?.querySelector("img")
    if (imgEl) {
      const src = imgEl.getAttribute("src")
      if (src) {
        try {
          const resolved = new URL(src, sourceUrl).toString()
          if (validateExternalUrl(resolved).ok) {
            webImages.push(resolved)
          }
        } catch {
          // skip invalid URLs
        }
      }
    }

    const priceInfo = extractPrice(surroundingText)

    seenTitles.add(title.toLowerCase())
    events.push({
      title,
      description: surroundingText.slice(0, 500),
      startDatetime,
      endDatetime: null,
      venueName: null,
      address: null,
      sourceUrl: normalizedUrl,
      imageUrl: webImages[0] ?? null,
      images: webImages,
      price: priceInfo.price,
      isFree: priceInfo.isFree,
    })
  }

  return events
}
