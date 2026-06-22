import { assertEquals } from "jsr:@std/assert"
import { sendResendEmail } from "../_shared/resend.ts"
import type { PublicIpResolver } from "../_shared/guarded-fetch.ts"

// No-op SSRF resolver — bypasses real DNS lookups in unit tests (no --allow-net).
const noopResolve: PublicIpResolver = (_url) => Promise.resolve({ ok: true })

// ---------------------------------------------------------------------------
// Tests: push-group batching logic
//
// Verifies that the batching logic in process-notification-queue groups
// push-eligible users by (event_id, change_type), so that send-push is
// invoked once per group rather than once per queue entry.
// ---------------------------------------------------------------------------

interface QueueEntry {
  id: string
  user_id: string
  event_id: string
  change_type: string
  change_detail: Record<string, unknown> | null
}

interface PushGroup {
  title: string
  body: string
  url: string
  userIds: string[]
}

/** Mirrors the changeSummary helper from the main function. */
function changeSummary(changeType: string, detail: Record<string, unknown> | null): string {
  switch (changeType) {
    case "cancelled":
      return "This event has been cancelled."
    case "time_changed": {
      const newStart = detail?.new_start
      if (typeof newStart === "string") return `Time changed to ${newStart}`
      return "The event time has changed."
    }
    default:
      return "This event has been updated."
  }
}

/**
 * Mirrors the push-grouping logic from process-notification-queue/index.ts.
 * Extracts only the batching part so it can be unit-tested without Deno.serve
 * or Supabase client dependencies.
 */
function buildPushGroups(
  entries: QueueEntry[],
  pushEligible: Set<string>, // user_ids with change_push = true
  appUrl: string,
  eventTitles: Map<string, string>
): Map<string, PushGroup> {
  const pushGroups = new Map<string, PushGroup>()

  for (const entry of entries) {
    if (!pushEligible.has(entry.user_id)) continue
    const eventTitle = eventTitles.get(entry.event_id) ?? "Unknown Event"
    const summary = changeSummary(entry.change_type, entry.change_detail)
    const notifTitle =
      entry.change_type === "cancelled" ? `Cancelled: ${eventTitle}` : `Updated: ${eventTitle}`
    const eventUrl = `${appUrl}/events/${entry.event_id}`
    const groupKey = `${entry.event_id}:${entry.change_type}`

    const existing = pushGroups.get(groupKey)
    if (existing) {
      existing.userIds.push(entry.user_id)
    } else {
      pushGroups.set(groupKey, {
        title: notifTitle,
        body: summary,
        url: eventUrl,
        userIds: [entry.user_id],
      })
    }
  }

  return pushGroups
}

// ---------------------------------------------------------------------------
// Test 1: 3 users, same event + change_type → one push group with 3 user_ids
// ---------------------------------------------------------------------------

Deno.test("3 users sharing same (event_id, change_type) produce one push group", () => {
  const entries: QueueEntry[] = [
    { id: "q1", user_id: "u1", event_id: "e1", change_type: "cancelled", change_detail: null },
    { id: "q2", user_id: "u2", event_id: "e1", change_type: "cancelled", change_detail: null },
    { id: "q3", user_id: "u3", event_id: "e1", change_type: "cancelled", change_detail: null },
  ]
  const eligible = new Set(["u1", "u2", "u3"])
  const titles = new Map([["e1", "Park Day"]])

  const groups = buildPushGroups(entries, eligible, "https://app.example.com", titles)

  assertEquals(groups.size, 1)
  const group = groups.get("e1:cancelled")!
  assertEquals(group.userIds.length, 3)
  assertEquals(group.userIds.includes("u1"), true)
  assertEquals(group.userIds.includes("u2"), true)
  assertEquals(group.userIds.includes("u3"), true)
  assertEquals(group.title, "Cancelled: Park Day")
})

// ---------------------------------------------------------------------------
// Test 2: two different events → two push groups
// ---------------------------------------------------------------------------

Deno.test("two different events produce two separate push groups", () => {
  const entries: QueueEntry[] = [
    { id: "q1", user_id: "u1", event_id: "e1", change_type: "cancelled", change_detail: null },
    { id: "q2", user_id: "u2", event_id: "e2", change_type: "cancelled", change_detail: null },
    { id: "q3", user_id: "u3", event_id: "e1", change_type: "cancelled", change_detail: null },
  ]
  const eligible = new Set(["u1", "u2", "u3"])
  const titles = new Map([
    ["e1", "Park Day"],
    ["e2", "Book Club"],
  ])

  const groups = buildPushGroups(entries, eligible, "https://app.example.com", titles)

  assertEquals(groups.size, 2)

  const g1 = groups.get("e1:cancelled")!
  assertEquals(g1.userIds.length, 2)
  assertEquals(g1.userIds.includes("u1"), true)
  assertEquals(g1.userIds.includes("u3"), true)

  const g2 = groups.get("e2:cancelled")!
  assertEquals(g2.userIds.length, 1)
  assertEquals(g2.userIds.includes("u2"), true)
})

// ---------------------------------------------------------------------------
// Test 3: same event, different change_types → two push groups
// ---------------------------------------------------------------------------

Deno.test("same event with different change_types produces two push groups", () => {
  const entries: QueueEntry[] = [
    { id: "q1", user_id: "u1", event_id: "e1", change_type: "cancelled", change_detail: null },
    { id: "q2", user_id: "u2", event_id: "e1", change_type: "time_changed", change_detail: null },
  ]
  const eligible = new Set(["u1", "u2"])
  const titles = new Map([["e1", "Park Day"]])

  const groups = buildPushGroups(entries, eligible, "https://app.example.com", titles)

  assertEquals(groups.size, 2)
  assertEquals(groups.has("e1:cancelled"), true)
  assertEquals(groups.has("e1:time_changed"), true)
})

// ---------------------------------------------------------------------------
// Test 4: user without change_push=true is excluded from push groups
// ---------------------------------------------------------------------------

Deno.test("user without push preference is excluded from push groups", () => {
  const entries: QueueEntry[] = [
    { id: "q1", user_id: "u1", event_id: "e1", change_type: "cancelled", change_detail: null },
    { id: "q2", user_id: "u2", event_id: "e1", change_type: "cancelled", change_detail: null }, // not eligible
    { id: "q3", user_id: "u3", event_id: "e1", change_type: "cancelled", change_detail: null },
  ]
  // u2 does not have change_push enabled
  const eligible = new Set(["u1", "u3"])
  const titles = new Map([["e1", "Park Day"]])

  const groups = buildPushGroups(entries, eligible, "https://app.example.com", titles)

  assertEquals(groups.size, 1)
  const group = groups.get("e1:cancelled")!
  assertEquals(group.userIds.length, 2)
  assertEquals(group.userIds.includes("u1"), true)
  assertEquals(group.userIds.includes("u3"), true)
  assertEquals(group.userIds.includes("u2"), false)
})

// ---------------------------------------------------------------------------
// Test 5: no push-eligible users → no push groups (no send-push call)
// ---------------------------------------------------------------------------

Deno.test("no push-eligible users produces no push groups", () => {
  const entries: QueueEntry[] = [
    { id: "q1", user_id: "u1", event_id: "e1", change_type: "cancelled", change_detail: null },
  ]
  const eligible = new Set<string>()
  const titles = new Map([["e1", "Park Day"]])

  const groups = buildPushGroups(entries, eligible, "https://app.example.com", titles)

  assertEquals(groups.size, 0)
})

// ---------------------------------------------------------------------------
// Test 6: group URL is the event URL, not a per-user deep-link
// ---------------------------------------------------------------------------

Deno.test("push group URL is the event page URL", () => {
  const entries: QueueEntry[] = [
    { id: "q1", user_id: "u1", event_id: "evt-abc", change_type: "cancelled", change_detail: null },
  ]
  const eligible = new Set(["u1"])
  const titles = new Map([["evt-abc", "My Event"]])

  const groups = buildPushGroups(entries, eligible, "https://app.example.com", titles)
  const group = groups.get("evt-abc:cancelled")!

  assertEquals(group.url, "https://app.example.com/events/evt-abc")
})

// ---------------------------------------------------------------------------
// Tests: sendResendEmail — SSRF-safe Resend path (change notification email)
// ---------------------------------------------------------------------------

interface CapturedResendRequest {
  url: string
  init: RequestInit
}

function makeMockResendFetch(
  status: number,
  responseBody: unknown = {}
): { fetch: typeof globalThis.fetch; captured: CapturedResendRequest[] } {
  const captured: CapturedResendRequest[] = []
  const mockFetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    captured.push({ url, init: init ?? {} })
    return Promise.resolve(
      new Response(JSON.stringify(responseBody), {
        status,
        headers: { "Content-Type": "application/json" },
      })
    )
  }
  return { fetch: mockFetch as typeof globalThis.fetch, captured }
}

Deno.test("sendResendEmail (notification-queue): 2xx returns { ok: true } and POSTs to Resend endpoint", async () => {
  const { fetch: mockFetch, captured } = makeMockResendFetch(200, { id: "re_xyz" })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendResendEmail(
      "test-api-key",
      {
        from: "Family Events <onboarding@resend.dev>",
        to: ["bob@test.com"],
        template: {
          id: "family-events-event-change",
          variables: {
            USERNAME: "Bob",
            EVENT_TITLE: "Park Day",
            CHANGE_SUMMARY: "This event has been cancelled.",
            EVENT_DATE: "Saturday, June 20",
            EVENT_LOCATION: "City Park",
            EVENT_URL: "https://app.example.com/events/e1",
          },
        },
      },
      { resolve: noopResolve }
    )

    assertEquals(result.ok, true)
    assertEquals(result.status, 200)
    assertEquals(captured.length, 1)
    assertEquals(captured[0].url, "https://api.resend.com/emails")

    const body = JSON.parse(captured[0].init.body as string)
    assertEquals(body.to, ["bob@test.com"])
    assertEquals(body.template.id, "family-events-event-change")
    assertEquals(body.template.variables.USERNAME, "Bob")
    assertEquals(body.template.variables.CHANGE_SUMMARY, "This event has been cancelled.")

    const authHeader = (captured[0].init.headers as Record<string, string>)["Authorization"]
    assertEquals(authHeader, "Bearer test-api-key")
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendResendEmail (notification-queue): non-2xx returns { ok: false, status, errorBody }", async () => {
  const { fetch: mockFetch } = makeMockResendFetch(500, { message: "internal error" })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendResendEmail(
      "test-api-key",
      {
        from: "f@r.dev",
        to: ["u@t.com"],
        template: { id: "family-events-event-change", variables: {} },
      },
      { resolve: noopResolve }
    )

    assertEquals(result.ok, false)
    assertEquals(result.status, 500)
    assertEquals(typeof result.errorBody, "string")
  } finally {
    globalThis.fetch = original
  }
})
