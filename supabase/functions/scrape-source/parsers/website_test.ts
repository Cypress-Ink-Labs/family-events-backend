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

  Deno.test("parseWebsite prefers Modern Events Calendar DOM titles and local times", () => {
    const html = `
      <html>
        <body>
          <dt class="mec-calendar-day" data-mec-cell="20260428">
            <a class="mec-monthly-tooltip event-single-link-simple" data-tooltip-content="#mec-tooltip-10562" href="/calendar-events/garden-talks-spring26/">
              <h4 class="mec-event-title">Garden Talks</h4>
            </a>
          </dt>
          <div id="mec-tooltip-10562">
            <div class="mec-tooltip-event-time"><i></i> 5:30 pm - 6:30 pm</div>
            <div class="mec-tooltip-event-desc">Garden Talks &#x1f331;
              Dig in with us this spring at Moncus Park.
              Dates: March 31, April 28, May 26Time: 5:30–6:30 PMWhat to Bring: curiosity , ...
            </div>
          </div>
          <script type="application/ld+json">
            {
              "@context": "http://schema.org",
              "@type": "Event",
              "startDate": "2026-04-28T12:30:00-05:00",
              "endDate": "2026-04-28T13:30:00-05:00",
              "description": "Garden Talks &#x1f331; Dig in with us this spring at Moncus Park. Dates: March 31, April 28, May 26Time: 5:30–6:30 PMWhat to Bring: curiosity &amp; gloves.",
              "image": "https://moncuspark.org/garden.jpg",
              "name": "Garden Talks &#x1f331; Dig in with us this spring at Moncus Park",
              "offers": { "price": "0" },
              "url": "https://moncuspark.org/calendar-events/garden-talks-spring26/"
            }
          </script>
        </body>
      </html>
    `

    const events = parseWebsite(html, "https://moncuspark.org/events/", "America/Chicago")

    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Garden Talks")
    assertEquals(events[0].startDatetime, "2026-04-28T22:30:00.000Z")
    assertEquals(events[0].endDatetime, "2026-04-28T23:30:00.000Z")
    assertEquals(events[0].description.includes("🌱"), true)
    assertEquals(events[0].description.includes("May 26 Time: 5:30-6:30 PM What to Bring"), true)
    assertEquals(events[0].isFree, true)
  })

  Deno.test("parseWebsite returns [] when no structured event data exists", () => {
    const events = parseWebsite(
      '<html><body><a href="/x">Link only</a></body></html>',
      "https://example.com"
    )
    assertEquals(events.length, 0)
  })
}
