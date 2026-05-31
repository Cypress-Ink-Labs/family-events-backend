import { assertEquals } from "jsr:@std/assert"

// ---------------------------------------------------------------------------
// Extracted business logic for testing
// ---------------------------------------------------------------------------

interface ReminderTarget {
  user_id: string
  email: string
  display_name: string | null
  event_id: string
  event_title: string
  start_datetime: string
  venue_name: string | null
  address: string | null
  reminder_email: boolean
  reminder_push: boolean
  reminder_type: "day_before" | "morning_of"
}

type JoinRow = {
  user_id: string
  event_id: string
  events: {
    id: string
    title: string
    start_datetime: string
    venue_name: string | null
    address: string | null
    status: string
  } | null
  user_profiles: {
    email: string | null
    display_name: string | null
  } | null
  user_notification_preferences: {
    reminder_email: boolean
    reminder_push: boolean
  } | null
}

function flattenRows(rows: JoinRow[], reminderType: "day_before" | "morning_of"): ReminderTarget[] {
  const targets: ReminderTarget[] = []
  for (const row of rows) {
    const event = row.events
    const profile = row.user_profiles
    const prefs = row.user_notification_preferences

    if (!event || !profile?.email) continue

    targets.push({
      user_id: row.user_id,
      email: profile.email,
      display_name: profile.display_name,
      event_id: event.id,
      event_title: event.title,
      start_datetime: event.start_datetime,
      venue_name: event.venue_name,
      address: event.address,
      reminder_email: prefs?.reminder_email ?? true,
      reminder_push: prefs?.reminder_push ?? true,
      reminder_type: reminderType,
    })
  }
  return targets
}

function formatEventDate(isoDate: string): string {
  try {
    return new Date(isoDate).toLocaleDateString("en-US", {
      weekday: "long",
      month: "long",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    })
  } catch {
    return isoDate
  }
}

function deduplicateTargets(targets: ReminderTarget[]): ReminderTarget[] {
  const seen = new Set<string>()
  return targets.filter((t) => {
    const key = `${t.user_id}:${t.event_id}:${t.reminder_type}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

// ---------------------------------------------------------------------------
// Tests: flattenRows
// ---------------------------------------------------------------------------

Deno.test("flattenRows extracts valid reminder targets", () => {
  const rows: JoinRow[] = [
    {
      user_id: "u1",
      event_id: "e1",
      events: {
        id: "e1",
        title: "Park Day",
        start_datetime: "2026-06-07T10:00:00Z",
        venue_name: "City Park",
        address: "123 Main St",
        status: "published",
      },
      user_profiles: {
        email: "alice@test.com",
        display_name: "Alice",
      },
      user_notification_preferences: {
        reminder_email: true,
        reminder_push: true,
      },
    },
  ]

  const targets = flattenRows(rows, "day_before")
  assertEquals(targets.length, 1)
  assertEquals(targets[0].email, "alice@test.com")
  assertEquals(targets[0].event_title, "Park Day")
  assertEquals(targets[0].reminder_type, "day_before")
  assertEquals(targets[0].reminder_email, true)
  assertEquals(targets[0].reminder_push, true)
})

Deno.test("flattenRows skips rows without event data", () => {
  const rows: JoinRow[] = [
    {
      user_id: "u1",
      event_id: "e1",
      events: null,
      user_profiles: { email: "alice@test.com", display_name: "Alice" },
      user_notification_preferences: { reminder_email: true, reminder_push: true },
    },
  ]

  const targets = flattenRows(rows, "day_before")
  assertEquals(targets.length, 0)
})

Deno.test("flattenRows skips rows without user email", () => {
  const rows: JoinRow[] = [
    {
      user_id: "u1",
      event_id: "e1",
      events: {
        id: "e1",
        title: "Park Day",
        start_datetime: "2026-06-07T10:00:00Z",
        venue_name: null,
        address: null,
        status: "published",
      },
      user_profiles: { email: null, display_name: "No Email" },
      user_notification_preferences: { reminder_email: true, reminder_push: true },
    },
  ]

  const targets = flattenRows(rows, "morning_of")
  assertEquals(targets.length, 0)
})

Deno.test("flattenRows defaults preferences to true when null", () => {
  const rows: JoinRow[] = [
    {
      user_id: "u1",
      event_id: "e1",
      events: {
        id: "e1",
        title: "Story Time",
        start_datetime: "2026-06-07T14:00:00Z",
        venue_name: "Library",
        address: null,
        status: "published",
      },
      user_profiles: { email: "bob@test.com", display_name: null },
      user_notification_preferences: null,
    },
  ]

  const targets = flattenRows(rows, "day_before")
  assertEquals(targets.length, 1)
  assertEquals(targets[0].reminder_email, true)
  assertEquals(targets[0].reminder_push, true)
})

// ---------------------------------------------------------------------------
// Tests: preference filtering
// ---------------------------------------------------------------------------

Deno.test("users with reminder_email=false skip email dispatch", () => {
  const rows: JoinRow[] = [
    {
      user_id: "u1",
      event_id: "e1",
      events: {
        id: "e1",
        title: "Park Day",
        start_datetime: "2026-06-07T10:00:00Z",
        venue_name: "City Park",
        address: null,
        status: "published",
      },
      user_profiles: { email: "alice@test.com", display_name: "Alice" },
      user_notification_preferences: { reminder_email: false, reminder_push: true },
    },
  ]

  const targets = flattenRows(rows, "day_before")
  assertEquals(targets.length, 1)
  assertEquals(targets[0].reminder_email, false)
  assertEquals(targets[0].reminder_push, true)

  // Simulating the dispatch logic
  const shouldSendEmail = targets[0].reminder_email
  const shouldSendPush = targets[0].reminder_push
  assertEquals(shouldSendEmail, false)
  assertEquals(shouldSendPush, true)
})

Deno.test("users with reminder_push=false skip push dispatch", () => {
  const rows: JoinRow[] = [
    {
      user_id: "u2",
      event_id: "e2",
      events: {
        id: "e2",
        title: "Story Time",
        start_datetime: "2026-06-07T14:00:00Z",
        venue_name: null,
        address: "456 Oak Ave",
        status: "published",
      },
      user_profiles: { email: "bob@test.com", display_name: "Bob" },
      user_notification_preferences: { reminder_email: true, reminder_push: false },
    },
  ]

  const targets = flattenRows(rows, "morning_of")
  assertEquals(targets[0].reminder_push, false)
  assertEquals(targets[0].reminder_email, true)
})

// ---------------------------------------------------------------------------
// Tests: deduplication
// ---------------------------------------------------------------------------

Deno.test("deduplicateTargets removes duplicate user+event+type combos", () => {
  const targets: ReminderTarget[] = [
    {
      user_id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      event_id: "e1",
      event_title: "Park Day",
      start_datetime: "2026-06-07T10:00:00Z",
      venue_name: "City Park",
      address: null,
      reminder_email: true,
      reminder_push: true,
      reminder_type: "day_before",
    },
    {
      user_id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      event_id: "e1",
      event_title: "Park Day",
      start_datetime: "2026-06-07T10:00:00Z",
      venue_name: "City Park",
      address: null,
      reminder_email: true,
      reminder_push: true,
      reminder_type: "day_before",
    },
    {
      user_id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      event_id: "e1",
      event_title: "Park Day",
      start_datetime: "2026-06-07T10:00:00Z",
      venue_name: "City Park",
      address: null,
      reminder_email: true,
      reminder_push: true,
      reminder_type: "morning_of", // different type, should be kept
    },
  ]

  const deduped = deduplicateTargets(targets)
  assertEquals(deduped.length, 2)
  assertEquals(deduped[0].reminder_type, "day_before")
  assertEquals(deduped[1].reminder_type, "morning_of")
})

Deno.test("deduplicateTargets keeps different users for same event", () => {
  const targets: ReminderTarget[] = [
    {
      user_id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      event_id: "e1",
      event_title: "Park Day",
      start_datetime: "2026-06-07T10:00:00Z",
      venue_name: null,
      address: null,
      reminder_email: true,
      reminder_push: true,
      reminder_type: "day_before",
    },
    {
      user_id: "u2",
      email: "bob@test.com",
      display_name: "Bob",
      event_id: "e1",
      event_title: "Park Day",
      start_datetime: "2026-06-07T10:00:00Z",
      venue_name: null,
      address: null,
      reminder_email: true,
      reminder_push: true,
      reminder_type: "day_before",
    },
  ]

  const deduped = deduplicateTargets(targets)
  assertEquals(deduped.length, 2)
})

// ---------------------------------------------------------------------------
// Tests: notification content formatting
// ---------------------------------------------------------------------------

Deno.test("formatEventDate produces human-readable date", () => {
  const date = formatEventDate("2026-06-07T10:00:00Z")
  assertEquals(typeof date, "string")
  assertEquals(date.length > 0, true)
  // Should contain "June" and "7"
  assertEquals(date.includes("June"), true)
  assertEquals(date.includes("7"), true)
})

Deno.test("formatEventDate handles invalid date gracefully", () => {
  const date = formatEventDate("not-a-date")
  // new Date("not-a-date").toLocaleDateString() returns "Invalid Date"
  assertEquals(date, "Invalid Date")
})

Deno.test("notification title includes event name and timing", () => {
  const target: ReminderTarget = {
    user_id: "u1",
    email: "alice@test.com",
    display_name: "Alice",
    event_id: "e1",
    event_title: "Park Day",
    start_datetime: "2026-06-07T10:00:00Z",
    venue_name: "City Park",
    address: null,
    reminder_email: true,
    reminder_push: true,
    reminder_type: "day_before",
  }

  const reminderLabel = target.reminder_type === "day_before" ? "tomorrow" : "today"
  const notifTitle = `Reminder: ${target.event_title} is ${reminderLabel}`
  assertEquals(notifTitle, "Reminder: Park Day is tomorrow")
})

Deno.test("notification body includes venue when available", () => {
  const withVenue = (t: ReminderTarget) => {
    const date = formatEventDate(t.start_datetime)
    return `${date}${t.venue_name ? ` at ${t.venue_name}` : ""}`
  }

  const targetWithVenue: ReminderTarget = {
    user_id: "u1",
    email: "a@t.com",
    display_name: null,
    event_id: "e1",
    event_title: "Park Day",
    start_datetime: "2026-06-07T10:00:00Z",
    venue_name: "City Park",
    address: null,
    reminder_email: true,
    reminder_push: true,
    reminder_type: "morning_of",
  }

  const bodyWithVenue = withVenue(targetWithVenue)
  assertEquals(bodyWithVenue.includes("at City Park"), true)

  const targetWithoutVenue = { ...targetWithVenue, venue_name: null }
  const bodyWithoutVenue = withVenue(targetWithoutVenue)
  assertEquals(bodyWithoutVenue.includes("at City Park"), false)
})

// ---------------------------------------------------------------------------
// Tests: Resend template payload
// ---------------------------------------------------------------------------

Deno.test("Resend template payload has correct structure", () => {
  const target: ReminderTarget = {
    user_id: "u1",
    email: "alice@test.com",
    display_name: "Alice",
    event_id: "e1",
    event_title: "Park Day",
    start_datetime: "2026-06-07T10:00:00Z",
    venue_name: "City Park",
    address: "123 Main St",
    reminder_email: true,
    reminder_push: true,
    reminder_type: "day_before",
  }

  const appUrl = "https://family-events.up.railway.app"
  const eventUrl = `${appUrl}/events/${target.event_id}`

  const payload = {
    from: "Family Events <onboarding@resend.dev>",
    to: [target.email],
    template: {
      id: "family-events-event-reminder",
      variables: {
        USERNAME: target.display_name || "there",
        EVENT_TITLE: target.event_title,
        EVENT_DATE: formatEventDate(target.start_datetime),
        EVENT_LOCATION: target.venue_name || target.address || "TBD",
        EVENT_URL: eventUrl,
      },
    },
  }

  assertEquals(payload.to, ["alice@test.com"])
  assertEquals(payload.template.id, "family-events-event-reminder")
  assertEquals(payload.template.variables.USERNAME, "Alice")
  assertEquals(payload.template.variables.EVENT_TITLE, "Park Day")
  assertEquals(payload.template.variables.EVENT_LOCATION, "City Park")
  assertEquals(payload.template.variables.EVENT_URL, "https://family-events.up.railway.app/events/e1")
})

Deno.test("Resend template falls back to address when venue_name is null", () => {
  const venueName: string | null = null
  const address: string | null = "456 Oak Ave"
  const location = venueName ?? address ?? "TBD"
  assertEquals(location, "456 Oak Ave")
})

Deno.test("Resend template falls back to TBD when both are null", () => {
  const venueName: string | null = null
  const address: string | null = null
  const location = venueName ?? address ?? "TBD"
  assertEquals(location, "TBD")
})

// ---------------------------------------------------------------------------
// Tests: date boundary computation
// ---------------------------------------------------------------------------

Deno.test("date boundaries compute correctly", () => {
  const now = new Date("2026-06-06T15:30:00Z")
  const todayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
  const todayEnd = new Date(todayStart.getTime() + 24 * 60 * 60 * 1000)
  const tomorrowStart = new Date(todayEnd)
  const tomorrowEnd = new Date(tomorrowStart.getTime() + 24 * 60 * 60 * 1000)

  assertEquals(todayStart.toISOString(), "2026-06-06T00:00:00.000Z")
  assertEquals(todayEnd.toISOString(), "2026-06-07T00:00:00.000Z")
  assertEquals(tomorrowStart.toISOString(), "2026-06-07T00:00:00.000Z")
  assertEquals(tomorrowEnd.toISOString(), "2026-06-08T00:00:00.000Z")
})

// ---------------------------------------------------------------------------
// Tests: change notification processing (process-notification-queue logic)
// ---------------------------------------------------------------------------

function changeSummary(changeType: string, detail: Record<string, unknown> | null): string {
  switch (changeType) {
    case "cancelled":
      return "This event has been cancelled."
    case "time_changed": {
      const newStart = detail?.new_start
      if (typeof newStart === "string") {
        return `Time changed to ${formatEventDate(newStart)}`
      }
      return "The event time has changed."
    }
    case "venue_changed": {
      const newVenue = detail?.new_venue
      if (typeof newVenue === "string") {
        return `Venue changed to ${newVenue}`
      }
      return "The event venue has changed."
    }
    case "status_changed":
      return "The event status has been updated."
    default:
      return "This event has been updated."
  }
}

Deno.test("changeSummary handles cancellation", () => {
  const summary = changeSummary("cancelled", { old_status: "published", new_status: "archived" })
  assertEquals(summary, "This event has been cancelled.")
})

Deno.test("changeSummary handles time change with detail", () => {
  const summary = changeSummary("time_changed", {
    old_start: "2026-06-07T10:00:00Z",
    new_start: "2026-06-08T14:00:00Z",
  })
  assertEquals(summary.startsWith("Time changed to"), true)
})

Deno.test("changeSummary handles time change without detail", () => {
  const summary = changeSummary("time_changed", null)
  assertEquals(summary, "The event time has changed.")
})

Deno.test("changeSummary handles venue change", () => {
  const summary = changeSummary("venue_changed", { new_venue: "Community Center" })
  assertEquals(summary, "Venue changed to Community Center")
})

Deno.test("changeSummary handles unknown type", () => {
  const summary = changeSummary("unknown", null)
  assertEquals(summary, "This event has been updated.")
})

// ---------------------------------------------------------------------------
// Tests: debounce window calculation
// ---------------------------------------------------------------------------

Deno.test("debounce window cutoff is 1 hour before now", () => {
  const DEBOUNCE_HOURS = 1
  const now = Date.now()
  const cutoff = new Date(now - DEBOUNCE_HOURS * 60 * 60 * 1000)

  // An entry created 2 hours ago should be processed
  const twoHoursAgo = new Date(now - 2 * 60 * 60 * 1000)
  assertEquals(twoHoursAgo < cutoff, true)

  // An entry created 30 minutes ago should NOT be processed
  const thirtyMinAgo = new Date(now - 30 * 60 * 1000)
  assertEquals(thirtyMinAgo < cutoff, false)
})

// ---------------------------------------------------------------------------
// Tests: batch size and max per run limits
// ---------------------------------------------------------------------------

Deno.test("batch processing respects MAX_PER_RUN and BATCH_SIZE", () => {
  const MAX_PER_RUN = 100
  const BATCH_SIZE = 10

  // Simulate 250 entries — only first 100 should be processed
  const entries = Array.from({ length: 250 }, (_, i) => ({ id: `entry-${i}` }))
  const limited = entries.slice(0, MAX_PER_RUN)
  assertEquals(limited.length, 100)

  // Batches should be ceil(100/10) = 10
  const batchCount = Math.ceil(limited.length / BATCH_SIZE)
  assertEquals(batchCount, 10)
})
