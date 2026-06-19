import { assert, assertEquals } from "jsr:@std/assert"
import { zonedDayStartUtc } from "../_shared/zoned-time.ts"

// ---------------------------------------------------------------------------
// send-reminders day-window + in-app row shape + push call.
//
// Complements send-reminders.test.ts (which covers flattenRows / dedup /
// formatEventDate / email template). Here we pin the exact four window bounds
// the handler computes, the in-app user_notifications row shape, and the
// send-push call body — with the network mocked.
// ---------------------------------------------------------------------------

const REMINDER_TZ = "America/Chicago"

// Mirror of index.ts window composition (index.ts:69-73).
function reminderWindows(now: Date, tz: string) {
  const todayStart = zonedDayStartUtc(now, tz, 0)
  const todayEnd = zonedDayStartUtc(now, tz, 1)
  const tomorrowStart = todayEnd
  const tomorrowEnd = zonedDayStartUtc(now, tz, 2)
  return { todayStart, todayEnd, tomorrowStart, tomorrowEnd }
}

Deno.test("morning-of window is the zone-local calendar day (CDT)", () => {
  // 2026-07-15T12:00:00Z = Jul 15 07:00 CDT (UTC-5).
  const now = new Date("2026-07-15T12:00:00Z")
  const { todayStart, todayEnd } = reminderWindows(now, REMINDER_TZ)
  assertEquals(todayStart.toISOString(), "2026-07-15T05:00:00.000Z")
  assertEquals(todayEnd.toISOString(), "2026-07-16T05:00:00.000Z")
})

Deno.test("day-before window is the next zone-local calendar day and abuts today", () => {
  const now = new Date("2026-07-15T12:00:00Z")
  const { todayEnd, tomorrowStart, tomorrowEnd } = reminderWindows(now, REMINDER_TZ)
  // tomorrowStart === todayEnd (no gap, no overlap)
  assertEquals(tomorrowStart.toISOString(), todayEnd.toISOString())
  assertEquals(tomorrowStart.toISOString(), "2026-07-16T05:00:00.000Z")
  assertEquals(tomorrowEnd.toISOString(), "2026-07-17T05:00:00.000Z")
})

Deno.test("windows respect standard time (CST, UTC-6)", () => {
  const now = new Date("2026-01-15T12:00:00Z")
  const { todayStart, todayEnd, tomorrowEnd } = reminderWindows(now, REMINDER_TZ)
  assertEquals(todayStart.toISOString(), "2026-01-15T06:00:00.000Z")
  assertEquals(todayEnd.toISOString(), "2026-01-16T06:00:00.000Z")
  assertEquals(tomorrowEnd.toISOString(), "2026-01-17T06:00:00.000Z")
})

Deno.test("an event near UTC midnight is bucketed by its Chicago calendar day", () => {
  // 03:00Z Jan 15 is still Jan 14 21:00 in Chicago, so "today" starts Jan 14.
  const now = new Date("2026-01-15T03:00:00Z")
  const { todayStart } = reminderWindows(now, REMINDER_TZ)
  assertEquals(todayStart.toISOString(), "2026-01-14T06:00:00.000Z")
})

// ---------------------------------------------------------------------------
// In-app notification row shape (index.ts:248-254).
// ---------------------------------------------------------------------------

interface ReminderTarget {
  user_id: string
  event_id: string
  event_title: string
  start_datetime: string
  venue_name: string | null
  reminder_type: "day_before" | "morning_of"
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

function buildInAppNotification(t: ReminderTarget) {
  const reminderLabel = t.reminder_type === "day_before" ? "tomorrow" : "today"
  const notifTitle = `Reminder: ${t.event_title} is ${reminderLabel}`
  const notifBody = `${formatEventDate(t.start_datetime)}${t.venue_name ? ` at ${t.venue_name}` : ""}`
  return {
    user_id: t.user_id,
    type: "reminder" as const,
    title: notifTitle,
    body: notifBody,
    event_id: t.event_id,
  }
}

Deno.test("in-app notification row has reminder type, title, body and event_id", () => {
  const target: ReminderTarget = {
    user_id: "u1",
    event_id: "e1",
    event_title: "Park Day",
    start_datetime: "2026-06-07T10:00:00Z",
    venue_name: "City Park",
    reminder_type: "day_before",
  }
  const row = buildInAppNotification(target)
  assertEquals(row.user_id, "u1")
  assertEquals(row.type, "reminder")
  assertEquals(row.event_id, "e1")
  assertEquals(row.title, "Reminder: Park Day is tomorrow")
  assert(row.body.includes("at City Park"))
})

Deno.test("in-app notification body omits venue clause when venue_name is null", () => {
  const target: ReminderTarget = {
    user_id: "u2",
    event_id: "e2",
    event_title: "Story Time",
    start_datetime: "2026-06-07T14:00:00Z",
    venue_name: null,
    reminder_type: "morning_of",
  }
  const row = buildInAppNotification(target)
  assertEquals(row.title, "Reminder: Story Time is today")
  // Body is exactly the formatted date with no trailing " at <venue>" clause.
  assertEquals(row.body, formatEventDate(target.start_datetime))
})

// ---------------------------------------------------------------------------
// send-push fan-out call shape (network mocked).
// ---------------------------------------------------------------------------

async function withFetch(fakeFetch: typeof fetch, fn: () => Promise<void>) {
  const originalFetch = globalThis.fetch
  globalThis.fetch = fakeFetch
  try {
    await fn()
  } finally {
    globalThis.fetch = originalFetch
  }
}

// Mirror of the send-push invocation in index.ts:325-342.
async function callSendPush(args: {
  supabaseUrl: string
  serviceRoleKey: string
  userId: string
  title: string
  body: string
  url: string
}): Promise<number> {
  const response = await fetch(`${args.supabaseUrl}/functions/v1/send-push`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${args.serviceRoleKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      user_id: args.userId,
      title: args.title,
      body: args.body,
      url: args.url,
    }),
  })
  if (!response.ok) return 0
  const result = (await response.json().catch(() => ({}))) as { sent?: number }
  return result.sent ?? 0
}

Deno.test("send-push call targets the function url with service-role auth and single-user payload", async () => {
  let captured: { url: string; init: RequestInit } | undefined
  const fakeFetch = ((url: string | URL | Request, init?: RequestInit) => {
    captured = { url: String(url), init: init ?? {} }
    return Promise.resolve(new Response(JSON.stringify({ sent: 2 }), { status: 200 }))
  }) as typeof fetch

  let sent = 0
  await withFetch(fakeFetch, async () => {
    sent = await callSendPush({
      supabaseUrl: "https://proj.supabase.co",
      serviceRoleKey: "svc-key",
      userId: "u1",
      title: "Reminder: Park Day is tomorrow",
      body: "Saturday at City Park",
      url: "https://app/events/e1",
    })
  })

  assertEquals(sent, 2)
  assert(captured !== undefined)
  const { url, init } = captured
  assertEquals(url, "https://proj.supabase.co/functions/v1/send-push")
  const headers = init.headers as Record<string, string>
  assertEquals(headers.Authorization, "Bearer svc-key")
  const body = JSON.parse(init.body as string) as { user_id: string; url: string }
  assertEquals(body.user_id, "u1")
  assertEquals(body.url, "https://app/events/e1")
})

Deno.test("send-push call contributes 0 sent on a non-2xx response", async () => {
  const fakeFetch = (() => Promise.resolve(new Response("err", { status: 500 }))) as typeof fetch
  let sent = -1
  await withFetch(fakeFetch, async () => {
    sent = await callSendPush({
      supabaseUrl: "https://proj.supabase.co",
      serviceRoleKey: "k",
      userId: "u1",
      title: "t",
      body: "b",
      url: "u",
    })
  })
  assertEquals(sent, 0)
})
