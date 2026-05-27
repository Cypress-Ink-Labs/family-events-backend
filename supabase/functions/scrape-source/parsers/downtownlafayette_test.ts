import { parseDowntownLafayetteEvents } from "./downtownlafayette.ts"

function assertEquals<T>(actual: T, expected: T, msg?: string): void {
  if (!Object.is(actual, expected)) {
    throw new Error(
      `${msg ?? "assertEquals"}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

function assert(condition: boolean, msg = "Assertion failed"): void {
  if (!condition) throw new Error(msg)
}

async function readFixture(relativePath: string): Promise<string> {
  return await Deno.readTextFile(new URL(`../__fixtures__/${relativePath}`, import.meta.url))
}

if (typeof Deno !== "undefined") {
  // Use a fixed "now" so year-inference is deterministic: 2026-05-01
  const NOW = new Date("2026-05-01T12:00:00Z")

  Deno.test("DDA parser: parses timed event with venue and image", async () => {
    const html = await readFixture("downtownlafayette/events-page.html")
    const events = parseDowntownLafayetteEvents(html, NOW)

    const book = events.find((e) => e.title?.includes("Shannon Terry Wiley"))
    assert(book !== undefined, "should find Shannon Terry Wiley event")
    // Jun 15 6:00 pm CDT = Jun 15 23:00 UTC
    assertEquals(book!.startDatetime, "2026-06-15T23:00:00.000Z")
    assertEquals(book!.endDatetime, "2026-06-16T01:00:00.000Z")
    assertEquals(book!.venueName, "Cavalier House Books - Lafayette")
    assert(book!.sourceUrl?.includes("/event/an-evening-with-shannon-terry-wiley") ?? false)
    assert(book!.imageUrl?.includes("event1.jpeg") ?? false, "should extract image from g_visual_img")
  })

  Deno.test("DDA parser: parses Bach Lunch with correct noon time", async () => {
    const html = await readFixture("downtownlafayette/events-page.html")
    const events = parseDowntownLafayetteEvents(html, NOW)

    const bach = events.find((e) => e.title?.includes("Bach Lunch"))
    assert(bach !== undefined, "should find Bach Lunch event")
    // Jun 20 11:00 am CDT = 16:00 UTC
    assertEquals(bach!.startDatetime, "2026-06-20T16:00:00.000Z")
    assertEquals(bach!.endDatetime, "2026-06-20T18:00:00.000Z")
    assertEquals(bach!.venueName, "Parc Sans Souci")
  })

  Deno.test("DDA parser: sourceUrl is absolute for /event/ href", async () => {
    const html = await readFixture("downtownlafayette/events-page.html")
    const events = parseDowntownLafayetteEvents(html, NOW)

    for (const e of events) {
      if (e.sourceUrl) {
        assert(
          e.sourceUrl.startsWith("https://"),
          `sourceUrl should be absolute: ${e.sourceUrl}`,
        )
      }
    }
  })

  Deno.test("DDA parser: all-day event (no time) defaults to midnight", async () => {
    const html = await readFixture("downtownlafayette/events-page.html")
    const events = parseDowntownLafayetteEvents(html, NOW)

    const fest = events.find((e) => e.title === "All-Day Festival")
    assert(fest !== undefined, "should find All-Day Festival")
    // No time in card — defaults to 00:00 CDT = 05:00 UTC
    assertEquals(fest!.startDatetime, "2026-07-04T05:00:00.000Z")
    assertEquals(fest!.endDatetime, null)
  })

  Deno.test("DDA parser: deduplicates repeated event keys", async () => {
    const html = await readFixture("downtownlafayette/events-page.html")
    const events = parseDowntownLafayetteEvents(html, NOW)
    const titles = events.map((e) => e.title)
    const unique = new Set(titles.map((t) => t?.toLowerCase() + "::" + (events.find((e) => e.title === t)?.startDatetime ?? "")))
    assertEquals(unique.size, events.length, "no duplicate title+time pairs")
  })

  Deno.test("DDA parser: returns expected event count", async () => {
    const html = await readFixture("downtownlafayette/events-page.html")
    const events = parseDowntownLafayetteEvents(html, NOW)
    assertEquals(events.length, 4)
  })

  Deno.test("DDA parser: empty HTML returns empty array", () => {
    const events = parseDowntownLafayetteEvents("<html><body></body></html>", NOW)
    assertEquals(events.length, 0)
  })
}
