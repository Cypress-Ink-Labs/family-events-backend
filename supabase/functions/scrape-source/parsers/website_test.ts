import { parseWebsite } from "./website.ts"

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

async function readFixture(relativePath: string): Promise<string> {
  return await Deno.readTextFile(new URL(`../__fixtures__/${relativePath}`, import.meta.url))
}

if (typeof Deno !== "undefined") {
  Deno.test("parseWebsite extracts schema.org Event JSON-LD and rejects date-less events", async () => {
    const html = await readFixture("html/events-page.html")
    const events = parseWebsite(html, "https://events.example.com/calendar")

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "City Science Fair")
    assertEquals(events[0].startDatetime, "2026-08-11T15:00:00.000Z")
    assertEquals(events[0].endDatetime, "2026-08-11T19:00:00.000Z")
    assertEquals(events[0].sourceUrl, "https://events.example.com/events/science-fair")
    assertEquals(events[0].venueName, "Riverfront Hall")
    assertEquals(events[0].address, "101 Main St")
    assertEquals(events[0].imageUrl, "https://events.example.com/science-fair.jpg")
    assertEquals(events[0].price, 0)
    assertEquals(events[0].isFree, true)
  })

  Deno.test("parseWebsite returns [] when no structured event data exists", () => {
    const events = parseWebsite("<html><body><a href=\"/x\">Link only</a></body></html>", "https://example.com")
    assertEquals(events.length, 0)
  })
}
