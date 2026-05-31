import "@supabase/functions-js/edge-runtime.d.ts"
import {
  serveServiceRoleJson,
} from "../_shared/service-role-handler.ts"
import { logEdgeEvent } from "../_shared/logger.ts"
import { cronRunContextFromRequest, logCronRunEvent } from "../_shared/cron-run-log.ts"

// process-notification-queue
// ----------------------------------------------------------------
// Cron-triggered edge function that reads pending entries from the
// notification_queue table (older than the 1-hour debounce window),
// groups by user, creates user_notification rows, and dispatches
// email + push respecting user preferences.
//
// Caps processing at 100 entries per run to avoid timeout.

const RESEND_API_ENDPOINT = "https://api.resend.com/emails"
const RESEND_TIMEOUT_MS = 10_000
const PUSH_TIMEOUT_MS = 10_000
const MAX_PER_RUN = 100
const DEBOUNCE_HOURS = 1
const BATCH_SIZE = 10
const BATCH_DELAY_MS = 300

interface QueueEntry {
  id: string
  user_id: string
  event_id: string
  change_type: string
  change_detail: Record<string, unknown> | null
  created_at: string
}

interface EventInfo {
  id: string
  title: string
  start_datetime: string
  venue_name: string | null
  address: string | null
  status: string
}

interface UserInfo {
  email: string | null
  display_name: string | null
}

interface UserPrefs {
  change_email: boolean
  change_push: boolean
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

serveServiceRoleJson(
  { functionName: "process-notification-queue" },
  async ({ request, supabase, supabaseUrl, serviceRoleKey }) => {
    const cronCtx = cronRunContextFromRequest(request)

    // 1. Read pending entries older than the debounce window
    const cutoff = new Date(Date.now() - DEBOUNCE_HOURS * 60 * 60 * 1000).toISOString()

    const { data: entries, error: queryErr } = await supabase
      .from("notification_queue")
      .select("id, user_id, event_id, change_type, change_detail, created_at")
      .eq("processed", false)
      .lt("created_at", cutoff)
      .order("created_at", { ascending: true })
      .limit(MAX_PER_RUN)

    if (queryErr) {
      await logCronRunEvent(supabase, cronCtx, "error", "Failed to query notification queue", {
        error: queryErr.message,
      })
      throw queryErr
    }

    if (!entries || entries.length === 0) {
      await logCronRunEvent(supabase, cronCtx, "log", "No pending queue entries", {})
      return { ok: true, processed: 0, sent_email: 0, sent_push: 0, in_app: 0 }
    }

    // 2. Collect unique event IDs and user IDs
    const eventIds = [...new Set(entries.map((e: QueueEntry) => e.event_id))]
    const userIds = [...new Set(entries.map((e: QueueEntry) => e.user_id))]

    // 3. Fetch event info
    const { data: events } = await supabase
      .from("events")
      .select("id, title, start_datetime, venue_name, address, status")
      .in("id", eventIds)

    const eventMap = new Map<string, EventInfo>()
    for (const e of (events ?? []) as EventInfo[]) {
      eventMap.set(e.id, e)
    }

    // 4. Fetch user info
    const { data: profiles } = await supabase
      .from("user_profiles")
      .select("id, email, display_name")
      .in("id", userIds)

    const profileMap = new Map<string, UserInfo>()
    for (const p of (profiles ?? []) as Array<{ id: string; email: string | null; display_name: string | null }>) {
      profileMap.set(p.id, { email: p.email, display_name: p.display_name })
    }

    // 5. Fetch user preferences
    const { data: prefs } = await supabase
      .from("user_notification_preferences")
      .select("user_id, change_email, change_push")
      .in("user_id", userIds)

    const prefsMap = new Map<string, UserPrefs>()
    for (const p of (prefs ?? []) as Array<{ user_id: string; change_email: boolean; change_push: boolean }>) {
      prefsMap.set(p.user_id, { change_email: p.change_email, change_push: p.change_push })
    }

    const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? ""
    const resendFrom = Deno.env.get("RESEND_FROM") ?? "Family Events <onboarding@resend.dev>"
    const appUrl = (Deno.env.get("APP_URL") ?? "https://family-events.up.railway.app").replace(/\/$/, "")

    let sentEmail = 0
    let sentPush = 0
    let inApp = 0
    let failedEmail = 0
    let failedPush = 0
    const processedIds: string[] = []

    // 6. Process entries in batches
    for (let i = 0; i < entries.length; i += BATCH_SIZE) {
      const batch = (entries as QueueEntry[]).slice(i, i + BATCH_SIZE)

      for (const entry of batch) {
        const event = eventMap.get(entry.event_id)
        const user = profileMap.get(entry.user_id)
        const userPrefs = prefsMap.get(entry.user_id) ?? { change_email: true, change_push: true }

        if (!event || !user?.email) {
          // Event deleted or user profile missing — mark processed and skip
          processedIds.push(entry.id)
          continue
        }

        const summary = changeSummary(entry.change_type, entry.change_detail)
        const notifTitle = entry.change_type === "cancelled"
          ? `Cancelled: ${event.title}`
          : `Updated: ${event.title}`
        const eventUrl = `${appUrl}/events/${entry.event_id}`

        // Create in-app notification
        const { error: notifErr } = await supabase
          .from("user_notifications")
          .insert({
            user_id: entry.user_id,
            type: "change" as const,
            title: notifTitle,
            body: summary,
            event_id: entry.event_id,
          })

        if (notifErr) {
          logEdgeEvent("warn", "process-notification-queue: failed to create in-app notification", {
            function: "process-notification-queue",
            user_id: entry.user_id,
            event_id: entry.event_id,
            error: notifErr.message,
          })
        } else {
          inApp++
        }

        // Send email if user wants change emails
        if (userPrefs.change_email && resendApiKey) {
          try {
            const response = await fetch(RESEND_API_ENDPOINT, {
              method: "POST",
              headers: {
                Authorization: `Bearer ${resendApiKey}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                from: resendFrom,
                to: [user.email],
                template: {
                  id: "family-events-event-change",
                  variables: {
                    USERNAME: user.display_name || "there",
                    EVENT_TITLE: event.title,
                    CHANGE_SUMMARY: summary,
                    EVENT_DATE: formatEventDate(event.start_datetime),
                    EVENT_LOCATION: event.venue_name || event.address || "TBD",
                    EVENT_URL: eventUrl,
                  },
                },
              }),
              signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
            })

            if (response.ok) {
              sentEmail++
            } else {
              const body = await response.text().catch(() => "")
              logEdgeEvent("warn", "process-notification-queue: Resend rejected email", {
                function: "process-notification-queue",
                to: user.email,
                status: response.status,
                body: body.slice(0, 300),
              })
              failedEmail++
            }
          } catch (err) {
            logEdgeEvent("warn", "process-notification-queue: email delivery error", {
              function: "process-notification-queue",
              to: user.email,
              error: err instanceof Error ? err.message : String(err),
            })
            failedEmail++
          }
        } else if (userPrefs.change_email && !resendApiKey) {
          logEdgeEvent("warn", "process-notification-queue: RESEND_API_KEY not configured", {
            function: "process-notification-queue",
            to: user.email,
          })
        }

        // Send push if user wants change push
        if (userPrefs.change_push) {
          try {
            const pushResponse = await fetch(
              `${supabaseUrl}/functions/v1/send-push`,
              {
                method: "POST",
                headers: {
                  Authorization: `Bearer ${serviceRoleKey}`,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({
                  user_id: entry.user_id,
                  title: notifTitle,
                  body: summary,
                  url: eventUrl,
                }),
                signal: AbortSignal.timeout(PUSH_TIMEOUT_MS),
              },
            )

            if (pushResponse.ok) {
              const result = await pushResponse.json().catch(() => ({})) as { sent?: number }
              sentPush += result.sent ?? 0
            } else {
              failedPush++
            }
          } catch (err) {
            logEdgeEvent("warn", "process-notification-queue: push delivery error", {
              function: "process-notification-queue",
              user_id: entry.user_id,
              error: err instanceof Error ? err.message : String(err),
            })
            failedPush++
          }
        }

        processedIds.push(entry.id)
      }

      // Rate-limit between batches
      if (i + BATCH_SIZE < entries.length) {
        await sleep(BATCH_DELAY_MS)
      }
    }

    // 7. Mark processed entries
    if (processedIds.length > 0) {
      const { error: updateErr } = await supabase
        .from("notification_queue")
        .update({ processed: true, processed_at: new Date().toISOString() })
        .in("id", processedIds)

      if (updateErr) {
        logEdgeEvent("error", "process-notification-queue: failed to mark entries processed", {
          function: "process-notification-queue",
          count: processedIds.length,
          error: updateErr.message,
        })
      }
    }

    const result = {
      ok: true,
      processed: processedIds.length,
      in_app: inApp,
      sent_email: sentEmail,
      sent_push: sentPush,
      failed_email: failedEmail,
      failed_push: failedPush,
    }

    await logCronRunEvent(supabase, cronCtx, "log", "process-notification-queue complete", result)
    logEdgeEvent("log", "process-notification-queue: complete", {
      function: "process-notification-queue",
      ...result,
    })

    return result
  },
)
