import { decodeHtml, extractPrice, parseIsoDate, stripHtml } from "../../_shared/parsing.ts"
import { validateExternalUrl } from "../../_shared/url-validation.ts"
import type { ParsedEvent } from "../lib/types.ts"

function extractImages(rawContent: string, baseUrl: string): string[] {
  const urls = new Set<string>()

  const patterns = [
    /<media:content[^>]+url=["']([^"']+)["'][^>]*\/?>/gi,
    /<media:thumbnail[^>]+url=["']([^"']+)["'][^>]*\/?>/gi,
    /<enclosure[^>]+url=["']([^"']+)["'][^>]+type=["']image\/[^"']+["'][^>]*\/?>/gi,
    /<enclosure[^>]+type=["']image\/[^"']+["'][^>]+url=["']([^"']+)["'][^>]*\/?>/gi,
    /<img[^>]+src=["']([^"']+)["'][^>]*\/?>/gi,
  ]

  for (const pattern of patterns) {
    for (const match of rawContent.matchAll(pattern)) {
      try {
        const resolved = new URL(match[1], baseUrl).toString()
        if (validateExternalUrl(resolved).ok) {
          urls.add(resolved)
        }
      } catch {
        // skip invalid URLs
      }
    }
  }

  return [...urls].slice(0, 5)
}

export function parseRssFeed(xml: string, sourceUrl: string): ParsedEvent[] {
  const itemMatches = [
    ...xml.matchAll(/<item[\s\S]*?<\/item>/gi),
    ...xml.matchAll(/<entry[\s\S]*?<\/entry>/gi),
  ]
  const results: ParsedEvent[] = []

  for (const [rawItem] of itemMatches) {
    const titleMatch =
      rawItem.match(/<title><!\[CDATA\[([\s\S]*?)\]\]><\/title>/i) ??
      rawItem.match(/<title>([\s\S]*?)<\/title>/i)
    const title = titleMatch ? stripHtml(titleMatch[1]) : ""
    if (!title) {
      continue
    }

    const descriptionMatch =
      rawItem.match(/<description><!\[CDATA\[([\s\S]*?)\]\]><\/description>/i) ??
      rawItem.match(/<description>([\s\S]*?)<\/description>/i) ??
      rawItem.match(/<summary>([\s\S]*?)<\/summary>/i)
    const description = descriptionMatch ? stripHtml(descriptionMatch[1]) : ""

    const linkMatch =
      rawItem.match(/<link>([\s\S]*?)<\/link>/i) ??
      rawItem.match(/<link[^>]*href=["']([^"']+)["'][^>]*\/?>/i)
    const sourceLink = linkMatch ? decodeHtml(linkMatch[1].trim()) : sourceUrl
    const normalizedSourceLink = sourceLink ? new URL(sourceLink, sourceUrl).toString() : null

    const dateMatch =
      rawItem.match(/<pubDate>([\s\S]*?)<\/pubDate>/i) ??
      rawItem.match(/<updated>([\s\S]*?)<\/updated>/i) ??
      rawItem.match(/<dc:date>([\s\S]*?)<\/dc:date>/i)
    const startDatetime = parseIsoDate(dateMatch?.[1]?.trim()) ?? new Date().toISOString()

    const images = extractImages(rawItem, sourceUrl)
    const rawDescription = descriptionMatch?.[1] ?? ""
    const priceInfo = extractPrice(rawDescription)

    results.push({
      title,
      description,
      startDatetime,
      endDatetime: null,
      venueName: null,
      address: null,
      sourceUrl: normalizedSourceLink,
      imageUrl: images[0] ?? null,
      images,
      price: priceInfo.price,
      isFree: priceInfo.isFree,
    })
  }

  return results
}
