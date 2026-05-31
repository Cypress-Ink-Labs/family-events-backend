import "@supabase/functions-js/edge-runtime.d.ts"
import {
  serveServiceRoleJson,
} from "../_shared/service-role-handler.ts"
import { logEdgeEvent } from "../_shared/logger.ts"
import { cronRunContextFromRequest, logCronRunEvent } from "../_shared/cron-run-log.ts"

// send-reminders
// ----------------------------------------------------------------
// Cron-triggered edge function that sends event reminders for:
//   1. Day-before reminders (events happening tomorrow)
//   2. Morning-of reminders (events happening today)
//
// For each qualifying user+event pair:
//   - Creates a user_notification row (in-app)
//   - Dispatches email via Resend (event-reminder template)
//   - Dispatches push via send-push edge function
// Respects user_notification_preferences (reminder_email/reminder_push).

const RESEND_API_ENDPOINT = "https://api.resend.com/emails"
const RESEND_TIMEOUT_MS = 10_000
const PUSH_TIMEOUT_MS = 10_000
const BATCH_SIZE = 10
const BATCH_DELAY_MS = 300

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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

serveServiceRoleJson(
  { functionName: "send-reminders" },
  async ({ request, supabase, supabaseUrl, serviceRoleKey }) => {
    const cronCtx = cronRunContextFromRequest(request)

    // Compute date boundaries in UTC
    const now = new Date()
    const todayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
    const todayEnd = new Date(todayStart.getTime() + 24 * 60 * 60 * 1000)
    const tomorrowStart = new Date(todayEnd)
    const tomorrowEnd = new Date(tomorrowStart.getTime() + 24 * 60 * 60 * 1000)

    // Query favorites (saved events) joined with events.
    // PostgREST cannot embed user_notification_preferences through
    // auth.users (same issue as send-weekly-digest), so preferences
    // are queried separately and joined in memory.
    //
    // Day-before: events starting tomorrow
    // Morning-of: events starting today
    const { data: dayBeforeRows, error: dbErr } = await supabase
      .from("favorites")
      .select(`
        user_id,
        event_id,
        events!inner(id, title, start_datetime, venue_name, address, status),
        user_profiles!inner(email, display_name)
      `)
      .gte("events.start_datetime", tomorrowStart.toISOString())
      .lt("events.start_datetime", tomorrowEnd.toISOString())
      .eq("events.status", "published")

    if (dbErr) {
      await logCronRunEvent(supabase, cronCtx, "error", "Failed to query day-before reminders", {
        error: dbErr.message,
      })
      throw dbErr
    }

    const { data: morningOfRows, error: moErr } = await supabase
      .from("favorites")
      .select(`
        user_id,
        event_id,
        events!inner(id, title, start_datetime, venue_name, address, status),
        user_profiles!inner(email, display_name)
      `)
      .gte("events.start_datetime", todayStart.toISOString())
      .lt("events.start_datetime", todayEnd.toISOString())
      .eq("events.status", "published")

    if (moErr) {
      await logCronRunEvent(supabase, cronCtx, "error", "Failed to query morning-of reminders", {
        error: moErr.message,
      })
      throw moErr
    }

    // Collect all user IDs from both result sets to batch-load preferences
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
    }

    const allRows = [...((dayBeforeRows ?? []) as unknown as JoinRow[]), ...((morningOfRows ?? []) as unknown as JoinRow[])]
    const userIdSet = new Set<string>()
    for (const row of allRows) {
      if (row.user_profiles?.email) userIdSet.add(row.user_id)
    }

    type PrefRow = { user_id: string; reminder_email: boolean; reminder_push: boolean }
    let prefMap = new Map<string, PrefRow>()

    if (userIdSet.size > 0) {
      const { data: prefRows, error: prefErr } = await supabase
        .from("user_notification_preferences")
        .select("user_id, reminder_email, reminder_push")
        .in("user_id", [...userIdSet])

      if (prefErr) {
        await logCronRunEvent(supabase, cronCtx, "error", "Failed to query notification preferences", {
          error: prefErr.message,
        })
        throw prefErr
      }

      for (const p of (prefRows ?? []) as unknown as PrefRow[]) {
        prefMap.set(p.user_id, p)
      }
    }

    function flattenRows(
      rows: unknown[],
      reminderType: "day_before" | "morning_of",
      prefs: Map<string, PrefRow>,
    ): ReminderTarget[] {
      const targets: ReminderTarget[] = []
      for (const raw of rows) {
        const row = raw as JoinRow
        const event = row.events as JoinRow["events"]
        const profile = row.user_profiles as JoinRow["user_profiles"]

        if (!event || !profile?.email) continue

        const userPref = prefs.get(row.user_id)

        targets.push({
          user_id: row.user_id,
          email: profile.email,
          display_name: profile.display_name,
          event_id: event.id,
          event_title: event.title,
          start_datetime: event.start_datetime,
          venue_name: event.venue_name,
          address: event.address,
          reminder_email: userPref?.reminder_email ?? true, // default true
          reminder_push: userPref?.reminder_push ?? true,   // default true
          reminder_type: reminderType,
        })
      }
      return targets
    }

    const targets = [
      ...flattenRows(dayBeforeRows ?? [], "day_before", prefMap),
      ...flattenRows(morningOfRows ?? [], "morning_of", prefMap),
    ]

    if (targets.length === 0) {
      await logCronRunEvent(supabase, cronCtx, "log", "No reminders to send", {})
      return { ok: true, sent_email: 0, sent_push: 0, in_app: 0, total: 0 }
    }

    // Deduplicate: a user+event combo should only get one reminder per run
    const seen = new Set<string>()
    const dedupedTargets = targets.filter((t) => {
      const key = `${t.user_id}:${t.event_id}:${t.reminder_type}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })

    const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? ""
    const resendFrom = Deno.env.get("RESEND_FROM") ?? "Family Events <onboarding@resend.dev>"
    const appUrl = (Deno.env.get("APP_URL") ?? "https://family-events.up.railway.app").replace(/\/$/, "")

    let sentEmail = 0
    let sentPush = 0
    let inApp = 0
    let failedEmail = 0
    let failedPush = 0

    for (let i = 0; i < dedupedTargets.length; i += BATCH_SIZE) {
      const batch = dedupedTargets.slice(i, i + BATCH_SIZE)

      for (const target of batch) {
        const reminderLabel = target.reminder_type === "day_before" ? "tomorrow" : "today"
        const notifTitle = `Reminder: ${target.event_title} is ${reminderLabel}`
        const notifBody = `${formatEventDate(target.start_datetime)}${target.venue_name ? ` at ${target.venue_name}` : ""}`
        const eventUrl = `${appUrl}/events/${target.event_id}`

        // 1. Create in-app notification
        const { error: notifErr } = await supabase
          .from("user_notifications")
          .insert({
            user_id: target.user_id,
            type: "reminder" as const,
            title: notifTitle,
            body: notifBody,
            event_id: target.event_id,
          })

        if (notifErr) {
          logEdgeEvent("warn", "send-reminders: failed to create in-app notification", {
            function: "send-reminders",
            user_id: target.user_id,
            event_id: target.event_id,
            error: notifErr.message,
          })
        } else {
          inApp++
        }

        // 2. Send email if user wants reminder emails
        if (target.reminder_email && resendApiKey) {
          try {
            const response = await fetch(RESEND_API_ENDPOINT, {
              method: "POST",
              headers: {
                Authorization: `Bearer ${resendApiKey}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                from: resendFrom,
                to: [target.email],
                template: {
                  id: "family-events-event-reminder",
                  variables: {
                    USERNAME: target.display_name || "there",
                    EVENT_TITLE: target.event_title,
                    EVENT_DATE: formatEventDate(target.start_datetime),
                    EVENT_LOCATION: target.venue_name || target.address || "TBD",
                    EVENT_URL: eventUrl,
                    LOGO_URL: `${appUrl}/brand/family-events-logo.png`,
                    APP_URL: appUrl,
                  },
                },
              }),
              signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
            })

            if (response.ok) {
              sentEmail++
            } else {
              const body = await response.text().catch(() => "")
              logEdgeEvent("warn", "send-reminders: Resend rejected email", {
                function: "send-reminders",
                to: target.email,
                status: response.status,
                body: body.slice(0, 300),
              })
              failedEmail++
            }
          } catch (err) {
            logEdgeEvent("warn", "send-reminders: email delivery error", {
              function: "send-reminders",
              to: target.email,
              error: err instanceof Error ? err.message : String(err),
            })
            failedEmail++
          }
        } else if (target.reminder_email && !resendApiKey) {
          logEdgeEvent("warn", "send-reminders: RESEND_API_KEY not configured; would have sent", {
            function: "send-reminders",
            to: target.email,
          })
        }

        // 3. Send push if user wants reminder push
        if (target.reminder_push) {
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
                  user_id: target.user_id,
                  title: notifTitle,
                  body: notifBody,
                  url: eventUrl,
                }),
                signal: AbortSignal.timeout(PUSH_TIMEOUT_MS),
              },
            )

            if (pushResponse.ok) {
              const result = await pushResponse.json().catch(() => ({})) as { sent?: number }
              sentPush += result.sent ?? 0
            } else {
              const body = await pushResponse.text().catch(() => "")
              logEdgeEvent("warn", "send-reminders: send-push call failed", {
                function: "send-reminders",
                user_id: target.user_id,
                status: pushResponse.status,
                body: body.slice(0, 300),
              })
              failedPush++
            }
          } catch (err) {
            logEdgeEvent("warn", "send-reminders: push delivery error", {
              function: "send-reminders",
              user_id: target.user_id,
              error: err instanceof Error ? err.message : String(err),
            })
            failedPush++
          }
        }
      }

      // Rate-limit between batches
      if (i + BATCH_SIZE < dedupedTargets.length) {
        await sleep(BATCH_DELAY_MS)
      }
    }

    const summary = {
      ok: true,
      total: dedupedTargets.length,
      in_app: inApp,
      sent_email: sentEmail,
      sent_push: sentPush,
      failed_email: failedEmail,
      failed_push: failedPush,
    }

    await logCronRunEvent(supabase, cronCtx, "log", "send-reminders complete", summary)
    logEdgeEvent("log", "send-reminders: complete", { function: "send-reminders", ...summary })

    return summary
  },
)
