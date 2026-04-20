import { parseRssFeed } from "./rss.ts"

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

async function readFixture(relativePath: string): Promise<string> {
  return await Deno.readTextFile(new URL(`../__fixtures__/${relativePath}`, import.meta.url))
}

if (typeof Deno !== "undefined") {
  Deno.test("parseRssFeed parses RSS item with CDATA, images, and price", async () => {
    const xml = await readFixture("rss/cdata-media.xml")
    const events = parseRssFeed(xml, "https://feed.example.com/rss.xml")

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Family Fun Night")
    assertStringIncludes(events[0].description, "Bring kids for games")
    assertEquals(events[0].startDatetime, "2026-04-15T14:30:00.000Z")
    assertEquals(events[0].sourceUrl, "https://feed.example.com/events/family-fun")
    assertEquals(events[0].price, 12.5)
    assert(events[0].images.includes("https://cdn.example.com/family-fun.jpg"))
    assert(events[0].images.includes("https://cdn.example.com/flyer.png"))
    assert(events[0].images.includes("https://feed.example.com/images/fun.jpg"))
  })

  Deno.test("parseRssFeed reads namespaced dc:date in RSS", async () => {
    const xml = await readFixture("rss/dc-date.xml")
    const events = parseRssFeed(xml, "https://feed.example.com/dc.xml")

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Community Picnic")
    assertEquals(events[0].startDatetime, "2026-05-02T15:00:00.000Z")
    assertEquals(events[0].isFree, true)
  })

  Deno.test("parseRssFeed parses Atom entry content and link href", async () => {
    const xml = await readFixture("atom/entry-content.xml")
    const events = parseRssFeed(xml, "https://atom.example.com/feed.xml")

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Neighborhood Meetup")
    assertEquals(events[0].startDatetime, "2026-06-01T23:00:00.000Z")
    assertStringIncludes(events[0].description, "Join us downtown")
    assertEquals(events[0].sourceUrl, "https://atom.example.com/events/meetup")
    assert(events[0].images.includes("https://atom.example.com/image.jpg"))
  })
}
