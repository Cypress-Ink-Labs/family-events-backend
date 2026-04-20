import { extractPrice, parseIcalDate, unescapeIcalText } from "../../_shared/parsing.ts"
import { validateExternalUrl } from "../../_shared/url-validation.ts"
import type { ParsedEvent } from "../lib/types.ts"

export function parseIcalFeed(icalContent: string): ParsedEvent[] {
  const blocks = icalContent.split("BEGIN:VEVENT").slice(1)
  const events: ParsedEvent[] = []

  for (const block of blocks) {
    const eventBlock = block.split("END:VEVENT")[0]
    if (!eventBlock) {
      continue
    }

    const rawSummary = eventBlock.match(/SUMMARY:(.+)/)?.[1]?.trim() ?? ""
    const summary = unescapeIcalText(rawSummary)
    if (!summary) {
      continue
    }

    const rawDescription = eventBlock.match(/DESCRIPTION:(.+)/)?.[1]?.trim() ?? ""
    const description = unescapeIcalText(rawDescription)
    const dtStartRaw = eventBlock.match(/DTSTART[^:]*:(.+)/)?.[1]?.trim() ?? null
    const dtEndRaw = eventBlock.match(/DTEND[^:]*:(.+)/)?.[1]?.trim() ?? null
    const rawLocation = eventBlock.match(/LOCATION:(.+)/)?.[1]?.trim() ?? null
    const location = rawLocation ? unescapeIcalText(rawLocation) : null
    const url = eventBlock.match(/URL:(.+)/)?.[1]?.trim() ?? null

    const startDatetime = parseIcalDate(dtStartRaw)
    if (!startDatetime) {
      continue
    }

    const attachMatches = [...eventBlock.matchAll(/ATTACH[^:]*:(.+)/g)]
    const icalImages: string[] = []
    for (const m of attachMatches) {
      const val = m[1].trim()
      if (
        /^https?:\/\/.+\.(jpg|jpeg|png|gif|webp)/i.test(val) &&
        validateExternalUrl(val).ok
      ) {
        icalImages.push(val)
      }
    }

    const priceInfo = extractPrice(description)

    events.push({
      title: summary,
      description,
      startDatetime,
      endDatetime: parseIcalDate(dtEndRaw),
      venueName: location,
      address: location,
      sourceUrl: url,
      imageUrl: icalImages[0] ?? null,
      images: icalImages.slice(0, 5),
      price: priceInfo.price,
      isFree: priceInfo.isFree,
    })
  }

  return events
}
