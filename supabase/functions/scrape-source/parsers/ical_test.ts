import { parseIcalFeed } from "./ical.ts"

function assert(condition: boolean, message = "Assertion failed"): void {
  if (!condition) {
    throw new Error(message)
  }
}

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

function assertStringIncludes(actual: string, expected: string): void {
  if (!actual.includes(expected)) {
    throw new Error(`Expected "${actual}" to include "${expected}"`)
  }
}

function assertThrows(fn: () => unknown, expectedMessageSubstring: string): void {
  let thrown: unknown = null
  try {
    fn()
  } catch (err) {
    thrown = err
  }
  if (!thrown) {
    throw new Error(`Expected throw containing "${expectedMessageSubstring}"`)
  }
  const message = thrown instanceof Error ? thrown.message : String(thrown)
  if (!message.includes(expectedMessageSubstring)) {
    throw new Error(
      `Expected throw to include "${expectedMessageSubstring}", got "${message}"`,
    )
  }
}

async function readFixture(relativePath: string): Promise<string> {
  return await Deno.readTextFile(new URL(`../__fixtures__/${relativePath}`, import.meta.url))
}

if (typeof Deno !== "undefined") {
  Deno.test("parseIcalFeed unfolds lines, respects TZID, and unescapes text", async () => {
    const ical = await readFixture("ical/folded-tzid.ics")
    const events = parseIcalFeed(ical)

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Neighborhood Orchestra")
    assertEquals(events[0].startDatetime, "2026-05-15T23:30:00.000Z")
    assertEquals(events[0].endDatetime, "2026-05-16T01:00:00.000Z")
    assertStringIncludes(events[0].description, "continuation text; bring chairs")
    assertStringIncludes(events[0].description, "Snacks included")
    assertEquals(events[0].venueName, "Town Hall, Main Street")
    assert(events[0].images.includes("https://calendar.example.com/poster.jpg"))
  })

  Deno.test("parseIcalFeed keeps RRULE events as single parsed instance", async () => {
    const ical = await readFixture("ical/rrule.ics")
    const events = parseIcalFeed(ical)

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Weekly Market")
    assertEquals(events[0].startDatetime, "2026-06-01T09:00:00.000Z")
    assertEquals(events[0].endDatetime, "2026-06-01T11:00:00.000Z")
    assertEquals(events[0].sourceUrl, "https://calendar.example.com/events/market")
  })

  Deno.test("parseIcalFeed throws on truncated feed missing END:VCALENDAR", () => {
    // Real-world failure mode: upstream returned a 23-byte fragment of a
    // VCALENDAR. The parser used to silently emit zero events; the worker
    // then surfaced a generic "no valid events" error that masked the
    // transport-layer truncation.
    const truncated = "BEGIN:VCALENDAR\nVERSI"
    assertThrows(() => parseIcalFeed(truncated), "Truncated iCal feed")
  })

  Deno.test("parseIcalFeed returns [] for empty body without VCALENDAR header", () => {
    assertEquals(parseIcalFeed("").length, 0)
    assertEquals(parseIcalFeed("\n\n").length, 0)
  })
}
