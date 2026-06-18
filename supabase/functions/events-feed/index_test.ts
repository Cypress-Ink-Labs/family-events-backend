import { assertEquals, assertMatch, assertStringIncludes } from "jsr:@std/assert";
import { handleEventsFeed, serializeIcal, serializeRss } from "./index.ts";

// ── Fixture ───────────────────────────────────────────────────────────────────

const SAMPLE_EVENTS = [
  {
    id: "11111111-2222-4333-8444-555555555555",
    title: "Kids Summer Fair, Fun & Games",
    description: "Join us for a fun\nsummer fair with games & prizes!",
    start_datetime: "2026-07-04T14:00:00.000Z",
    end_datetime: "2026-07-04T18:00:00.000Z",
    timezone: "America/Chicago",
    venue_name: "City Park",
    address: "123 Main St; Suite 1",
    source_url: "https://example.com/event/1",
    recurrence_info: null,
  },
  {
    id: "aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee",
    title: 'Storytime <Books> & "Crafts"',
    description: null,
    start_datetime: "2026-07-10T10:00:00.000Z",
    end_datetime: null,
    timezone: "America/New_York",
    venue_name: null,
    address: null,
    source_url: null,
    recurrence_info: { rrule: "FREQ=WEEKLY;COUNT=4" },
  },
];

// ── iCal serializer tests ─────────────────────────────────────────────────────

if (typeof Deno !== "undefined") {
  Deno.test("serializeIcal produces valid VCALENDAR envelope", () => {
    const ical = serializeIcal(SAMPLE_EVENTS, "Test Calendar");
    assertStringIncludes(ical, "BEGIN:VCALENDAR\r\n");
    assertStringIncludes(ical, "END:VCALENDAR\r\n");
    assertStringIncludes(ical, "VERSION:2.0\r\n");
    assertStringIncludes(ical, "CALSCALE:GREGORIAN\r\n");
  });

  Deno.test("serializeIcal emits one VEVENT per event", () => {
    const ical = serializeIcal(SAMPLE_EVENTS, "Test Calendar");
    const beginCount = (ical.match(/BEGIN:VEVENT/g) ?? []).length;
    const endCount = (ical.match(/END:VEVENT/g) ?? []).length;
    assertEquals(beginCount, 2);
    assertEquals(endCount, 2);
  });

  Deno.test("serializeIcal escapes commas, semicolons, and newlines in text fields (RFC 5545)", () => {
    const ical = serializeIcal([SAMPLE_EVENTS[0]], "Test");
    // Title: "Kids Summer Fair, Fun & Games" → comma escaped as \,
    assertStringIncludes(ical, "SUMMARY:Kids Summer Fair\\, Fun & Games");
    // Description: newline → \n
    assertStringIncludes(ical, "DESCRIPTION:Join us for a fun\\nsummer fair with games & prizes!");
    // Address: semicolon escaped as \;
    assertStringIncludes(ical, "LOCATION:City Park\\, 123 Main St\\; Suite 1");
  });

  Deno.test("serializeIcal escapes angle brackets and quotes via iCal escaping (not XML)", () => {
    const ical = serializeIcal([SAMPLE_EVENTS[1]], "Test");
    // Title has < > and " — iCal does NOT escape these as entities; they pass through raw
    assertStringIncludes(ical, 'SUMMARY:Storytime <Books> & "Crafts"');
    // Specifically: no &lt; or &amp; in iCal output
    assertEquals(ical.includes("&lt;"), false);
    assertEquals(ical.includes("&amp;"), false);
  });

  Deno.test("serializeIcal uses UTC DTSTART/DTEND format", () => {
    const ical = serializeIcal([SAMPLE_EVENTS[0]], "Test");
    assertStringIncludes(ical, "DTSTART:20260704T140000Z");
    assertStringIncludes(ical, "DTEND:20260704T180000Z");
  });

  Deno.test("serializeIcal falls back to dtstart + 1h when end_datetime is null", () => {
    const ical = serializeIcal([SAMPLE_EVENTS[1]], "Test");
    // start = 2026-07-10T10:00:00Z → end fallback = 2026-07-10T11:00:00Z
    assertStringIncludes(ical, "DTSTART:20260710T100000Z");
    assertStringIncludes(ical, "DTEND:20260710T110000Z");
  });

  Deno.test("serializeIcal uses CRLF line endings throughout", () => {
    const ical = serializeIcal(SAMPLE_EVENTS, "Test Calendar");
    // All lines (except the last empty after final CRLF) should end with CRLF
    const lines = ical.split("\r\n");
    // Last element after split on final CRLF is an empty string
    assertEquals(lines[lines.length - 1], "");
    // No bare \n (i.e. \n not preceded by \r) should exist — all newlines are CRLF
    assertEquals(/(?<!\r)\n/.test(ical), false);
  });

  Deno.test("serializeIcal includes UID and URL for each event", () => {
    const ical = serializeIcal([SAMPLE_EVENTS[0]], "Test");
    assertStringIncludes(ical, `UID:${SAMPLE_EVENTS[0].id}@family-events.org`);
    assertStringIncludes(ical, `URL:https://family-events.org/events/${SAMPLE_EVENTS[0].id}`);
  });

  // ── RSS serializer tests ───────────────────────────────────────────────────

  Deno.test("serializeRss produces valid RSS 2.0 envelope", () => {
    const rss = serializeRss(SAMPLE_EVENTS, "Test Feed", "https://example.com/feed");
    assertStringIncludes(rss, `<?xml version="1.0" encoding="UTF-8"?>`);
    assertStringIncludes(rss, `<rss version="2.0">`);
    assertStringIncludes(rss, `<channel>`);
    assertStringIncludes(rss, `</channel>`);
    assertStringIncludes(rss, `</rss>`);
  });

  Deno.test("serializeRss emits one item per event", () => {
    const rss = serializeRss(SAMPLE_EVENTS, "Test Feed", "https://example.com/feed");
    const itemCount = (rss.match(/<item>/g) ?? []).length;
    assertEquals(itemCount, 2);
  });

  Deno.test('serializeRss XML-escapes title containing < > & " characters', () => {
    const rss = serializeRss([SAMPLE_EVENTS[1]], "Test Feed", "https://example.com/feed");
    // Title: 'Storytime <Books> & "Crafts"' → XML escaped
    assertStringIncludes(rss, "&lt;Books&gt;");
    assertStringIncludes(rss, "&amp;");
    assertStringIncludes(rss, "&quot;Crafts&quot;");
  });

  Deno.test("serializeRss XML-escapes title containing commas (passthrough, no iCal escaping)", () => {
    const rss = serializeRss([SAMPLE_EVENTS[0]], "Test Feed", "https://example.com/feed");
    // Commas are NOT escaped in RSS/XML
    assertStringIncludes(rss, "<title>Kids Summer Fair, Fun &amp; Games</title>");
  });

  Deno.test("serializeRss omits description element when null", () => {
    const rss = serializeRss([SAMPLE_EVENTS[1]], "Test Feed", "https://example.com/feed");
    assertEquals(rss.includes("<description></description>"), false);
  });

  Deno.test("serializeRss includes guid and pubDate", () => {
    const rss = serializeRss([SAMPLE_EVENTS[0]], "Test Feed", "https://example.com/feed");
    assertStringIncludes(rss, `<guid isPermaLink="false">${SAMPLE_EVENTS[0].id}</guid>`);
    assertMatch(rss, /<pubDate>.+<\/pubDate>/);
  });

  // ── Handler tests ──────────────────────────────────────────────────────────

  Deno.test("handleEventsFeed rejects non-GET methods", async () => {
    const res = await handleEventsFeed(
      new Request("https://app.example.com/functions/v1/events-feed", { method: "POST" }),
    );
    assertEquals(res.status, 405);
  });

  Deno.test("handleEventsFeed rejects unknown format parameter", async () => {
    const res = await handleEventsFeed(
      new Request("https://app.example.com/functions/v1/events-feed?format=json"),
    );
    assertEquals(res.status, 400);
  });

  Deno.test("handleEventsFeed returns text/calendar for format=ics (no DB available)", async () => {
    // No env vars set → fetchPublishedEvents returns [] → empty but valid feed
    const res = await handleEventsFeed(
      new Request("https://app.example.com/functions/v1/events-feed?format=ics"),
    );
    assertEquals(res.status, 200);
    assertMatch(res.headers.get("Content-Type") ?? "", /text\/calendar/);
    const body = await res.text();
    assertStringIncludes(body, "BEGIN:VCALENDAR");
    assertStringIncludes(body, "END:VCALENDAR");
  });

  Deno.test("handleEventsFeed returns application/rss+xml for format=rss (no DB available)", async () => {
    const res = await handleEventsFeed(
      new Request("https://app.example.com/functions/v1/events-feed?format=rss"),
    );
    assertEquals(res.status, 200);
    assertMatch(res.headers.get("Content-Type") ?? "", /application\/rss\+xml/);
    const body = await res.text();
    assertStringIncludes(body, '<rss version="2.0">');
  });

  Deno.test("handleEventsFeed defaults to RSS when format param is absent", async () => {
    const res = await handleEventsFeed(
      new Request("https://app.example.com/functions/v1/events-feed"),
    );
    assertEquals(res.status, 200);
    assertMatch(res.headers.get("Content-Type") ?? "", /application\/rss\+xml/);
  });
}
