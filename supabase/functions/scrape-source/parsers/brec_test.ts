import { parseBrecCalendar } from "./brec.ts";

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
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
    `;

    const events = parseBrecCalendar(html, "https://www.brec.org/calendar", "America/Chicago");
    assertEquals(events.length, 3);

    const [first, second, third] = events;
    assertEquals(first.title, "Perkins Trail Blazers");
    assertEquals(first.venueName, "Perkins Road Community Park");
    assertEquals(
      first.sourceUrl,
      "https://www.brec.org/calendar/detail/perkins-trail-blazers/22908",
    );
    // all-day -> 00:00 local start, 23:59 local end. Chicago is UTC-5 in May (CDT).
    assertEquals(first.startDatetime, "2026-05-01T05:00:00.000Z");
    assertEquals(first.endDatetime, "2026-05-02T04:59:00.000Z");

    assertEquals(second.title, "Busy Bodies");
    assertEquals(second.startDatetime, "2026-05-01T13:30:00.000Z");
    assertEquals(second.endDatetime, "2026-05-01T14:30:00.000Z");

    assertEquals(third.title, "Bridge Club");
    assertEquals(third.venueName, "Anna T. Jordan Community Park");
    assertEquals(third.startDatetime, "2026-05-02T14:00:00.000Z");
    assertEquals(third.endDatetime, "2026-05-02T20:00:00.000Z");
  });

  Deno.test("parseBrecCalendar parses flat articles from category snippet API", () => {
    const html = `
      <html><body>
        <article class="extended">
          <h2>Monday, June 1, 2026</h2>
          <h3>BREC T-Ball</h3>
          <span class="time">6:00 PM <br>-<br> 9:00 PM</span>
          <span class="park">Hartley/Vey Sports Park (Oak Villa)</span>
          <a href="/calendar/detail/brec-tball/21546">BREC T-Ball</a>
        </article>
        <article class="extended">
          <h2>Monday, June 1, 2026</h2>
          <h3>BREC Coach Pitch</h3>
          <span class="time">6:00 PM <br>-<br> 9:00 PM</span>
          <span class="park">Hartley/Vey Sports Park (Oak Villa)</span>
          <a href="/calendar/detail/brec-coach-pitch/21562">BREC Coach Pitch</a>
        </article>
        <article class="extended">
          <h2>Tuesday, June 2, 2026</h2>
          <h3>BREC Girls Fast Pitch Softball</h3>
          <span class="time">6:00 PM <br>-<br> 9:00 PM</span>
          <span class="park">Hartley/Vey Sports Park (Oak Villa)</span>
          <a href="/calendar/detail/brec-girls-fast-pitch-softball/21595">BREC Girls Fast Pitch Softball</a>
        </article>
      </body></html>
    `;
    const events = parseBrecCalendar(
      html,
      "https://www.brec.org/calendar/category/KidsCalendar",
      "America/Chicago",
    );
    assertEquals(events.length, 3);

    assertEquals(events[0].title, "BREC T-Ball");
    assertEquals(events[0].venueName, "Hartley/Vey Sports Park (Oak Villa)");
    assertEquals(events[0].sourceUrl, "https://www.brec.org/calendar/detail/brec-tball/21546");
    // 6 PM CDT (UTC-5) = 23:00 UTC
    assertEquals(events[0].startDatetime, "2026-06-01T23:00:00.000Z");
    assertEquals(events[0].endDatetime, "2026-06-02T02:00:00.000Z");

    assertEquals(events[1].title, "BREC Coach Pitch");
    assertEquals(events[2].title, "BREC Girls Fast Pitch Softball");
    // June 2 at 6 PM CDT = 23:00 UTC
    assertEquals(events[2].startDatetime, "2026-06-02T23:00:00.000Z");
  });

  Deno.test("parseBrecCalendar returns [] when no events-list and no articles present", () => {
    const events = parseBrecCalendar(
      "<html><body><div>nothing</div></body></html>",
      "https://www.brec.org/calendar",
    );
    assertEquals(events.length, 0);
  });

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
    `;
    const events = parseBrecCalendar(html, "https://www.brec.org/calendar", "America/Chicago");
    assertEquals(events.length, 1);
    assertEquals(events[0].title, "Adopted");
  });
}
