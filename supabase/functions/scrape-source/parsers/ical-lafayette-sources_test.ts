/**
 * Tests for the three new Lafayette iCal sources using the existing icalParser.
 * All use The Events Calendar (ECPv6) WordPress plugin — iCal feeds are
 * structurally identical and handled by the existing parseIcalFeed function.
 *
 * Covers:
 *   - Lafayette Mom  (thelafayettemom.com/events/?ical=1)
 *   - Hilliard Art Museum  (hilliardartmuseum.org/events/?ical=1)
 *   - Vermilionville  (bayouvermiliondistrict.org/events/?ical=1)
 */

import { parseIcalFeed } from "./ical.ts"

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

// ---------------------------------------------------------------------------
// Lafayette Mom
// ---------------------------------------------------------------------------

if (typeof Deno !== "undefined") {
  Deno.test("Lafayette Mom iCal: parses timed event with TZID", async () => {
    const ical = await readFixture("ical/lafayette-mom-sample.ics")
    const events = parseIcalFeed(ical)

    const timed = events.find((e) => e.title === "Stay & Play: West Regional Library")
    assert(timed !== undefined, "should find timed event")
    // 9:30 AM CDT (UTC-5) = 14:30 UTC
    assertEquals(timed!.startDatetime, "2026-06-01T14:30:00.000Z")
    assertEquals(timed!.endDatetime, "2026-06-01T15:30:00.000Z")
    assert(
      timed!.sourceUrl?.includes("thelafayettemom.com") ?? false,
      "sourceUrl should point to lafayettemom.com",
    )
  })

  Deno.test("Lafayette Mom iCal: parses all-day DATE event (no time)", async () => {
    const ical = await readFixture("ical/lafayette-mom-sample.ics")
    const events = parseIcalFeed(ical)

    const allDay = events.find((e) => e.title === "Book Buddy: West Regional Library")
    assert(allDay !== undefined, "should find all-day event")
    // VALUE=DATE with no TZID should produce a UTC midnight start
    assert(allDay!.startDatetime.startsWith("2026-06-07"), "start date should be 2026-06-07")
    assert(allDay!.description.length > 0, "description should be populated")
  })

  Deno.test("Lafayette Mom iCal: returns expected event count", async () => {
    const ical = await readFixture("ical/lafayette-mom-sample.ics")
    const events = parseIcalFeed(ical)
    assertEquals(events.length, 2)
  })

  // ---------------------------------------------------------------------------
  // Hilliard Art Museum
  // ---------------------------------------------------------------------------

  Deno.test("Hilliard iCal: parses family event with LOCATION, CATEGORIES, and ATTACH image", async () => {
    const ical = await readFixture("ical/hilliard-sample.ics")
    const events = parseIcalFeed(ical)

    const cafe = events.find((e) => e.title?.includes("Create & Play Café"))
    assert(cafe !== undefined, "should find Create & Play Café event")
    assertEquals(
      cafe!.venueName,
      "Hilliard Art Museum, 710 E St Mary Blvd, Lafayette, LA, 70503, United States",
    )
    assertEquals(
      cafe!.address,
      "Hilliard Art Museum, 710 E St Mary Blvd, Lafayette, LA, 70503, United States",
    )
    assert(
      cafe!.imageUrl?.includes("kids-cafe.webp") ?? false,
      "should extract webp image from ATTACH",
    )
    assert(cafe!.description.includes("ages 4 and up"), "description should be preserved")
  })

  Deno.test("Hilliard iCal: parses Learn-category event with image", async () => {
    const ical = await readFixture("ical/hilliard-sample.ics")
    const events = parseIcalFeed(ical)

    const tour = events.find((e) => e.title?.includes("Gulf Streams"))
    assert(tour !== undefined, "should find guided tour event")
    assert(tour!.imageUrl !== null, "should have image from ATTACH")
    assert(
      tour!.sourceUrl?.includes("hilliardartmuseum.org") ?? false,
      "sourceUrl should point to hilliardartmuseum.org",
    )
  })

  Deno.test("Hilliard iCal: returns expected event count", async () => {
    const ical = await readFixture("ical/hilliard-sample.ics")
    const events = parseIcalFeed(ical)
    assertEquals(events.length, 2)
  })

  // ---------------------------------------------------------------------------
  // Vermilionville
  // ---------------------------------------------------------------------------

  Deno.test("Vermilionville iCal: parses recurring weekly Cajun Jam with image", async () => {
    const ical = await readFixture("ical/vermilionville-sample.ics")
    const events = parseIcalFeed(ical)

    const jam = events.find((e) => e.title?.includes("CFMA Cajun Jam"))
    assert(jam !== undefined, "should find Cajun Jam event")
    // 1 PM CDT = 18:00 UTC
    assertEquals(jam!.startDatetime, "2026-05-30T18:00:00.000Z")
    assertEquals(jam!.endDatetime, "2026-05-30T20:00:00.000Z")
    assertEquals(
      jam!.venueName,
      "Vermilionville, 300 Fisher Road, Lafayette, LA, 70508, United States",
    )
    assert(
      jam!.imageUrl?.includes("cajunjam3.jpg") ?? false,
      "should extract jpeg image from ATTACH",
    )
    assert(jam!.isFree === true, "Cajun Jam is free — should detect from description")
  })

  Deno.test("Vermilionville iCal: parses Homeschool Days event", async () => {
    const ical = await readFixture("ical/vermilionville-sample.ics")
    const events = parseIcalFeed(ical)

    const homeschool = events.find((e) => e.title?.includes("Homeschool Days"))
    assert(homeschool !== undefined, "should find Homeschool Days event")
    assert(homeschool!.description.length > 0, "description should be populated")
    assert(
      homeschool!.sourceUrl?.includes("bayouvermiliondistrict.org") ?? false,
      "sourceUrl should point to bayouvermiliondistrict.org",
    )
    // $6 / $10 admission — not free
    assertEquals(homeschool!.isFree, false)
  })

  Deno.test("Vermilionville iCal: returns expected event count", async () => {
    const ical = await readFixture("ical/vermilionville-sample.ics")
    const events = parseIcalFeed(ical)
    assertEquals(events.length, 2)
  })
}
