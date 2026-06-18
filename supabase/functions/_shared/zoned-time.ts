// Returns the UTC Date for midnight (00:00:00) of the zone-local calendar day
// at (now + dayOffset days).  dayOffset 0 = start of the current zone-local day,
// 1 = start of tomorrow, 2 = start of the day after, etc.
//
// Implementation uses Intl.DateTimeFormat to read the wall-clock Y/M/D in the
// target zone, derives the zone's current UTC offset from those parts, then
// constructs zone-local midnight as a UTC instant.  No external dependencies —
// Deno and V8 both implement Intl.
//
// DST safety: the offset is recalculated each call from the supplied `now`, so
// it reflects the actual offset at that instant rather than a cached value.
//
// NOTE: This hardcodes a single timezone for callers like send-reminders.
// If multi-region support is ever added, callers must pass the per-event or
// per-user timezone and the single-global-window query approach will need to
// change accordingly.
export function zonedDayStartUtc(now: Date, timeZone: string, dayOffset: number): Date {
  // Step 1 — read the zone-local wall-clock year/month/day for `now`.
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
    hour12: false,
  });

  const parts = fmt.formatToParts(now);
  const get = (type: string) => {
    const part = parts.find((p) => p.type === type);
    if (!part) throw new Error(`Intl part "${type}" missing for timezone "${timeZone}"`);
    return parseInt(part.value, 10);
  };

  const year = get("year");
  const month = get("month") - 1; // Intl months are 1-based; Date.UTC months are 0-based
  const day = get("day");

  // Step 2 — derive the zone's UTC offset at this instant.
  // Treat the wall-clock parts as if they were a UTC time and subtract `now`.
  // The difference is (zone-local wall clock - UTC), i.e. the UTC offset in ms.
  const wallAsUtcMs = Date.UTC(year, month, day, get("hour"), get("minute"), get("second"));
  const offsetMs = wallAsUtcMs - now.getTime();

  // Step 3 — zone-local midnight of (today + dayOffset) as a UTC instant.
  // Date.UTC(year, month, day + dayOffset) gives midnight of that day *as if* in
  // UTC.  Subtracting the offset converts it to the real UTC instant.
  return new Date(Date.UTC(year, month, day + dayOffset) - offsetMs);
}
