import { assertEquals, assertRejects } from "jsr:@std/assert"
import { fetchMacaroniKidEvents, mapMacaroniKidEvent } from "./macaroni-kid.ts"
import type { EventSourceRow } from "../lib/types.ts"

async function readFixture(relativePath: string): Promise<string> {
  return await Deno.readTextFile(new URL(`../__fixtures__/${relativePath}`, import.meta.url))
}

function buildSource(overrides: Partial<EventSourceRow> = {}): EventSourceRow {
  return {
    id: "00000000-0000-0000-0000-000000000001",
    name: "Macaroni Kid Lafayette",
    url: "https://lafayettela.macaronikid.com/events",
    source_type: "macaronikid",
    extraction_mode: "deterministic",
    city_id: "00000000-0000-0000-0000-0000000000aa",
    is_active: true,
    auto_approve: false,
    scrape_interval_hours: 12,
    last_scraped_at: null,
    last_status: null,
    error_count: 0,
    date_window_days: 30,
    ...overrides,
  }
}

if (typeof Deno !== "undefined") {
  Deno.test("mapMacaroniKidEvent constructs ParsedEvent from JSON node", () => {
    const raw = {
      _id: "abc123",
      slug: "park-day",
      name: "Park Day",
      start: "2026-06-01T14:00:00.000Z",
      end: "2026-06-01T16:00:00.000Z",
      location: { name: "Moncus Park", address: "2913 Johnston St", city: "Lafayette", state: "LA" },
      cost: "Free",
      who: "Toddlers",
      where: "Playground",
      how: "Drop in",
      image: "https://images.macaronikid.com/park.jpg",
    }
    const parsed = mapMacaroniKidEvent(raw, "https://lafayettela.macaronikid.com/events")
    if (!parsed) throw new Error("expected parsed event")
    assertEquals(parsed.title, "Park Day")
    assertEquals(parsed.startDatetime, "2026-06-01T14:00:00.000Z")
    assertEquals(parsed.endDatetime, "2026-06-01T16:00:00.000Z")
    assertEquals(parsed.venueName, "Moncus Park")
    assertEquals(parsed.address, "2913 Johnston St, Lafayette, LA")
    assertEquals(parsed.sourceUrl, "https://lafayettela.macaronikid.com/events/abc123/park-day")
    assertEquals(parsed.isFree, true)
    assertEquals(parsed.imageUrl, "https://images.macaronikid.com/park.jpg")
  })

  Deno.test("mapMacaroniKidEvent rejects nodes without title or start", () => {
    assertEquals(mapMacaroniKidEvent({ start: "2026-06-01T14:00:00Z" }, "https://x.example/events"), null)
    assertEquals(mapMacaroniKidEvent({ name: "No date" }, "https://x.example/events"), null)
    assertEquals(mapMacaroniKidEvent(null, "https://x.example/events"), null)
  })

  Deno.test("mapMacaroniKidEvent accepts startDateTime/endDateTime (real API shape)", () => {
    // Macaroni Kid API returns startDateTime/endDateTime, not start/end or startDate/endDate.
    // Earlier regression: all events dropped because parser only checked start/startDate.
    const raw = {
      _id: "real1",
      title: "Real API Event",
      startDateTime: "2026-07-01T15:00:00.000Z",
      endDateTime: "2026-07-01T17:00:00.000Z",
      location: { name: "Some Venue" },
    }
    const parsed = mapMacaroniKidEvent(raw, "https://lafayettela.macaronikid.com/events")
    if (!parsed) throw new Error("expected parsed event")
    assertEquals(parsed.title, "Real API Event")
    assertEquals(parsed.startDatetime, "2026-07-01T15:00:00.000Z")
    assertEquals(parsed.endDatetime, "2026-07-01T17:00:00.000Z")
  })

  Deno.test("fetchMacaroniKidEvents two-hop fetch + town extraction + mapping", async () => {
    const html = await readFixture("macaronikid/lafayette-page.html")
    const apiJson = await readFixture("macaronikid/lafayette-api.json")
    const source = buildSource()
    const calls: string[] = []

    const fetchText = (url: string) => {
      calls.push(`text:${url}`)
      return Promise.resolve(html)
    }
    const fetchJson = <T,>(url: string): Promise<T> => {
      calls.push(`json:${url}`)
      return Promise.resolve(JSON.parse(apiJson) as T)
    }

    const events = await fetchMacaroniKidEvents(
      source,
      fetchText,
      fetchJson,
      new Date("2026-05-16T00:00:00.000Z")
    )

    assertEquals(events.length, 2)
    assertEquals(calls[0], "text:https://lafayettela.macaronikid.com/events")
    const apiCall = calls[1]
    if (!apiCall.startsWith("json:https://api.macaronikid.com/api/v1/event/v2?query=")) {
      throw new Error(`unexpected api url: ${apiCall}`)
    }
    if (!apiCall.includes("58252a7a6f1aaf645c94f083")) {
      throw new Error(`townId missing from api url: ${apiCall}`)
    }
    if (!apiCall.includes("limit=802")) {
      throw new Error(`limit missing from api url: ${apiCall}`)
    }

    const story = events[0]
    assertEquals(story.title, "Family Storytime at the Library")
    assertEquals(story.venueName, "Lafayette Main Library")
    assertEquals(story.address, "301 W Congress St, Lafayette, LA, 70501")
    assertEquals(story.sourceUrl, "https://lafayettela.macaronikid.com/events/65d000000000000000000001/family-storytime-at-the-library")
    assertEquals(story.isFree, true)
    assertEquals(story.imageUrl, "https://images.macaronikid.com/storytime.jpg")

    const music = events[1]
    assertEquals(music.title, "Summer Music Night")
    assertEquals(music.isFree, false)
    assertEquals(music.price, 10)
    assertEquals(music.images.length, 2)
  })

  Deno.test("fetchMacaroniKidEvents throws when data-town attribute is missing", async () => {
    const source = buildSource()
    await assertRejects(
      () =>
        fetchMacaroniKidEvents(
          source,
          () => Promise.resolve("<html><body>no town here</body></html>"),
          <T,>(): Promise<T> => Promise.reject(new Error("should not call API"))
        ),
      Error,
      "data-town"
    )
  })

  Deno.test("fetchMacaroniKidEvents accepts wrapped response shapes ({events: [...]})", async () => {
    const html = await readFixture("macaronikid/lafayette-page.html")
    const source = buildSource()
    const events = await fetchMacaroniKidEvents(
      source,
      () => Promise.resolve(html),
      <T,>() =>
        Promise.resolve({
          events: [
            {
              _id: "x1",
              slug: "wrapped",
              name: "Wrapped Event",
              start: "2026-06-01T14:00:00Z",
            },
          ],
        } as T)
    )
    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Wrapped Event")
  })

  Deno.test("fetchMacaroniKidEvents respects date_window_days override in API URL", async () => {
    const html = await readFixture("macaronikid/lafayette-page.html")
    const source = buildSource({ date_window_days: 7 })
    let capturedUrl = ""
    await fetchMacaroniKidEvents(
      source,
      () => Promise.resolve(html),
      <T,>(url: string) => {
        capturedUrl = url
        return Promise.resolve([] as unknown as T)
      },
      new Date("2026-05-16T00:00:00.000Z")
    )
    if (!capturedUrl.includes(encodeURIComponent("2026-05-23T00:00:00.000Z"))) {
      throw new Error(`expected 7-day window end in url, got ${capturedUrl}`)
    }
  })
}

  Deno.test("mapMacaroniKidEvent reads top-level address object (real API v1 shape)", () => {
    // Real Macaroni Kid API v1 returns address data as a top-level 'address' object
    // (street1, city, state, zipCode) and venue name in the 'where' field.
    // The 'location' object only carries GeoJSON coordinates and should not be
    // used for geocoding eligibility.
    const raw = {
      _id: "69efca2a1944d7714560fffc",
      title: "Splash Pad!",
      startDateTime: "2026-05-26T15:00:00.000Z",
      where: "Broussard Sports Complex - St. Julien Park",
      address: {
        street1: "701 St. Nazaire",
        street2: "",
        city: "Broussard",
        state: "LA",
        zipCode: "70518",
      },
      location: { coordinates: [0, 0], type: "Point" },
      cost: "FREE",
    }
    const parsed = mapMacaroniKidEvent(raw, "https://lafayettela.macaronikid.com/events")
    if (!parsed) throw new Error("expected parsed event")
    assertEquals(parsed.venueName, "Broussard Sports Complex - St. Julien Park")
    assertEquals(parsed.address, "701 St. Nazaire, Broussard, LA, 70518")
    assertEquals(parsed.isFree, true)
  })
