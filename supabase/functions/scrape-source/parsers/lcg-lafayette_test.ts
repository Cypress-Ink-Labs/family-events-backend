import { parseLcgEventUrl, parseLcgEvents } from "./lcg-lafayette.ts"

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
  // ---------------------------------------------------------------------------
  // parseLcgEventUrl
  // ---------------------------------------------------------------------------

  Deno.test("parseLcgEventUrl: extracts datetime from standard slug", () => {
    const { startDatetime } = parseLcgEventUrl(
      "https://events.lafayettela.gov/default/detail/2026-05-27-1730-2026-Disaster-Ready-Workshop",
    )
    // 17:30 CDT (UTC-5) = 22:30 UTC
    assertEquals(startDatetime, "2026-05-27T22:30:00.000Z")
  })

  Deno.test("parseLcgEventUrl: extracts morning event (09:00 CDT = 14:00 UTC)", () => {
    const { startDatetime } = parseLcgEventUrl(
      "https://events.lafayettela.gov/default/detail/2026-06-02-0900-Summer-Splash-Kids-Camp",
    )
    assertEquals(startDatetime, "2026-06-02T14:00:00.000Z")
  })

  Deno.test("parseLcgEventUrl: returns null for unrecognised slug", () => {
    const { startDatetime } = parseLcgEventUrl("https://events.lafayettela.gov/default/detail/some-event")
    assertEquals(startDatetime, null)
  })

  // ---------------------------------------------------------------------------
  // parseLcgEvents
  // ---------------------------------------------------------------------------

  Deno.test("LCG parser: parses all events from fixture", async () => {
    const html = await readFixture("lcglafayette/events-page.html")
    const events = parseLcgEvents(html)
    assertEquals(events.length, 3)
  })

  Deno.test("LCG parser: extracts title and datetime for first event", async () => {
    const html = await readFixture("lcglafayette/events-page.html")
    const events = parseLcgEvents(html)

    const workshop = events.find((e) => e.title?.includes("Disaster Ready"))
    assert(workshop !== undefined, "should find Disaster Ready Workshop")
    assertEquals(workshop!.startDatetime, "2026-05-27T22:30:00.000Z")
    assert(
      workshop!.sourceUrl?.includes("events.lafayettela.gov") ?? false,
      "sourceUrl should be the events.lafayettela.gov URL",
    )
  })

  Deno.test("LCG parser: extracts family-relevant Summer Camp event", async () => {
    const html = await readFixture("lcglafayette/events-page.html")
    const events = parseLcgEvents(html)

    const camp = events.find((e) => e.title?.includes("Summer Splash"))
    assert(camp !== undefined, "should find Summer Splash Kids Camp")
    assertEquals(camp!.startDatetime, "2026-06-02T14:00:00.000Z")
    assertEquals(camp!.venueName, null, "no venue on listing page — expected null")
  })

  Deno.test("LCG parser: empty HTML returns empty array", () => {
    const events = parseLcgEvents("<html><body></body></html>")
    assertEquals(events.length, 0)
  })

  Deno.test("LCG parser: deduplicates identical title+datetime pairs", () => {
    const html = `<html><body><ul class="gs-feed-list-events">
      <li class="gs-feed-list-item">
        <div class="gs-feed-list-meta">
          <a href="https://events.lafayettela.gov/default/detail/2026-07-01-1000-Test-Event" class="gs-feed-list-title">Test Event</a>
        </div>
      </li>
      <li class="gs-feed-list-item">
        <div class="gs-feed-list-meta">
          <a href="https://events.lafayettela.gov/default/detail/2026-07-01-1000-Test-Event" class="gs-feed-list-title">Test Event</a>
        </div>
      </li>
    </ul></body></html>`
    const events = parseLcgEvents(html)
    assertEquals(events.length, 1)
  })
}
