import { assertEquals } from "jsr:@std/assert"
import { parseLocalHopEvents } from "./localhop.ts"

if (typeof Deno !== "undefined") {
  Deno.test("parseLocalHopEvents maps EventInstance API rows to parsed events", () => {
    const json = {
      results: [
        {
          objectId: "w0HShsCRHs",
          standardStartDate: { __type: "Date", iso: "2026-06-03T15:30:00.000Z" },
          standardEndDate: { __type: "Date", iso: "2026-06-03T16:00:00.000Z" },
          event: {
            name: "Toddler Time Storytime",
            description: "<p>Storytime for babies walking to age 2.</p>",
            slug: "toddler-time-storytime",
            address: {
              place: "East Baton Rouge Parish Library Bluebonnet Regional",
              address1: "9200 Bluebonnet Boulevard",
              city: "Baton Rouge",
              state: "LA",
              postalCode: "70810",
            },
            photo: {
              url: "https://localhop-prod.s3.amazonaws.com/uploads/storytime.png",
            },
          },
          slug: "toddler-time-storytime",
        },
      ],
    }

    const events = parseLocalHopEvents(json)

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Toddler Time Storytime")
    assertEquals(events[0].description, "Storytime for babies walking to age 2.")
    assertEquals(events[0].startDatetime, "2026-06-03T15:30:00.000Z")
    assertEquals(events[0].endDatetime, "2026-06-03T16:00:00.000Z")
    assertEquals(events[0].venueName, "East Baton Rouge Parish Library Bluebonnet Regional")
    assertEquals(events[0].address, "9200 Bluebonnet Boulevard, Baton Rouge, LA, 70810")
    assertEquals(events[0].sourceUrl, "https://events.getlocalhop.com/toddler-time-storytime/event/w0HShsCRHs/")
    assertEquals(events[0].imageUrl, "https://localhop-prod.s3.amazonaws.com/uploads/storytime.png")
  })

  Deno.test("parseLocalHopEvents skips rows without usable date or title", () => {
    const events = parseLocalHopEvents({
      results: [
        { objectId: "date-less", event: { name: "No date" } },
        { objectId: "title-less", standardStartDate: { iso: "2026-06-03T15:30:00.000Z" }, event: {} },
      ],
    })

    assertEquals(events.length, 0)
  })
}
