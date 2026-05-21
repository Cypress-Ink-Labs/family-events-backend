import { parseBrecCalendar } from "./brec.ts"

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

if (typeof Deno !== "undefined") {
  Deno.test("parseBrecCalendar walks day-header + article siblings and emits ParsedEvents", () => {
    const html = `
      <html><body>
        <section class="events-list">
          <header class="day-header" data-day="1">
            <h2>Friday, May 1, 2026</h2>
          </header>
          <article>
            <h3>Perkins Trail Blazers</h3>
            <span class="time"> <br>all day<br> </span>
            <span class="park">Perkins Road Community Park</span>
            <span class="day-index">Day 121 of 151</span>
            <a href="/calendar/detail/perkins-trail-blazers/22908">Perkins Trail Blazers</a>
          </article>
          <article>
            <h3>Busy Bodies</h3>
            <span class="time">8:30 AM <br>-<br> 9:30 AM</span>
            <span class="park">Independence Community Park</span>
            <a href="/calendar/detail/busy-bodies/24998">Busy Bodies</a>
          </article>
          <header class="day-header" data-day="2">
            <h2>Saturday, May 2, 2026</h2>
          </header>
          <article>
            <h3>Bridge Club</h3>
            <span class="time">9:00 AM <br>-<br> 3:00 PM</span>
            <span class="park">Anna T. Jordan Community Park</span>
            <a href="/calendar/detail/bridge-club/25114">Bridge Club</a>
          </article>
        </section>
      </body></html>
    `

    const events = parseBrecCalendar(html, "https://www.brec.org/calendar", "America/Chicago")
    assertEquals(events.length, 3)

    const [first, second, third] = events
    assertEquals(first.title, "Perkins Trail Blazers")
    assertEquals(first.venueName, "Perkins Road Community Park")
    assertEquals(first.sourceUrl, "https://www.brec.org/calendar/detail/perkins-trail-blazers/22908")
    // all-day -> 00:00 local start, 23:59 local end. Chicago is UTC-5 in May (CDT).
    assertEquals(first.startDatetime, "2026-05-01T05:00:00.000Z")
    assertEquals(first.endDatetime, "2026-05-02T04:59:00.000Z")

    assertEquals(second.title, "Busy Bodies")
    assertEquals(second.startDatetime, "2026-05-01T13:30:00.000Z")
    assertEquals(second.endDatetime, "2026-05-01T14:30:00.000Z")

    assertEquals(third.title, "Bridge Club")
    assertEquals(third.venueName, "Anna T. Jordan Community Park")
    assertEquals(third.startDatetime, "2026-05-02T14:00:00.000Z")
    assertEquals(third.endDatetime, "2026-05-02T20:00:00.000Z")
  })

  Deno.test("parseBrecCalendar returns [] when no events-list present", () => {
    const events = parseBrecCalendar(
      "<html><body><div>nothing</div></body></html>",
      "https://www.brec.org/calendar",
    )
    assertEquals(events.length, 0)
  })

  Deno.test("parseBrecCalendar drops articles preceding the first day-header", () => {
    const html = `
      <html><body>
        <section class="events-list">
          <article>
            <h3>Orphan</h3>
            <span class="time">9:00 AM</span>
            <a href="/calendar/detail/orphan/1">x</a>
          </article>
          <header class="day-header" data-day="1"><h2>Friday, May 1, 2026</h2></header>
          <article>
            <h3>Adopted</h3>
            <span class="time">10:00 AM</span>
            <a href="/calendar/detail/adopted/2">x</a>
          </article>
        </section>
      </body></html>
    `
    const events = parseBrecCalendar(html, "https://www.brec.org/calendar", "America/Chicago")
    assertEquals(events.length, 1)
    assertEquals(events[0].title, "Adopted")
  })
}
