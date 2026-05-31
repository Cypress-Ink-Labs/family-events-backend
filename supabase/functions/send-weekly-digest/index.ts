import "@supabase/functions-js/edge-runtime.d.ts";
import {
  serveServiceRoleJson,
  serviceRoleJsonError,
} from "../_shared/service-role-handler.ts";
import { logEdgeEvent } from "../_shared/logger.ts";
import { cronRunContextFromRequest, logCronRunEvent } from "../_shared/cron-run-log.ts";

// send-weekly-digest
// ----------------------------------------------------------------
// Cron-triggered edge function that sends branded weekly digest emails
// to users who have digest_email=true. For each user, queries upcoming
// published events in their city for the next 7 days. Skips users whose
// city has no events. Sends via Resend API following the notify-email
// pattern. Rate-limits with small delays between batches.

const RESEND_API_ENDPOINT = "https://api.resend.com/emails";
const RESEND_TIMEOUT_MS = 10_000;
const BATCH_SIZE = 5;
const BATCH_DELAY_MS = 500;
const MAX_EVENTS_PER_DIGEST = 10;

interface DigestUser {
  user_id: string;
  email: string;
  display_name: string | null;
  city_id: string;
  city_name: string;
}

interface DigestPreference {
  user_id: string;
}

interface DigestEvent {
  id: string;
  title: string;
  start_datetime: string;
  venue_name: string | null;
  address: string | null;
  is_free: boolean;
  price: number | null;
  images: Array<{ url?: string }> | null;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatDate(isoDate: string): string {
  try {
    const d = new Date(isoDate);
    return d.toLocaleDateString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  } catch {
    return isoDate;
  }
}

function formatPrice(event: DigestEvent): string {
  if (event.is_free) return "Free";
  if (event.price != null) return `$${Number(event.price).toFixed(2)}`;
  return "";
}

function renderEventCardHtml(event: DigestEvent, appUrl: string): string {
  const eventUrl = `${appUrl}/events/${event.id}`;
  const thumbnail = event.images?.[0]?.url;
  const location = event.venue_name || event.address || "";
  const price = formatPrice(event);

  return `
    <div style="border:1px solid #e2e8f0;border-radius:8px;padding:16px;margin:0 40px 12px;">
      <table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
        <tr>
          ${
            thumbnail
              ? `<td width="80" valign="top" style="padding-right:12px;">
                  <img src="${escapeHtml(thumbnail)}" width="80" height="60"
                       style="border-radius:6px;object-fit:cover;display:block;" alt="" />
                </td>`
              : ""
          }
          <td valign="top">
            <a href="${escapeHtml(eventUrl)}" style="font-size:15px;font-weight:600;color:#0f172a;text-decoration:none;">
              ${escapeHtml(event.title)}
            </a>
            <div style="font-size:13px;color:#64748b;margin-top:4px;">
              ${escapeHtml(formatDate(event.start_datetime))}
            </div>
            ${location ? `<div style="font-size:13px;color:#64748b;margin-top:2px;">${escapeHtml(location)}</div>` : ""}
            ${price ? `<div style="font-size:13px;color:#475569;font-weight:500;margin-top:2px;">${escapeHtml(price)}</div>` : ""}
          </td>
        </tr>
      </table>
    </div>`;
}

function renderDigestHtml(
  user: DigestUser,
  events: DigestEvent[],
  appUrl: string,
): string {
  const username = escapeHtml(user.display_name || "there");
  const cityName = escapeHtml(user.city_name);
  const eventCount = String(events.length);
  const eventsHtml = events.map((e) => renderEventCardHtml(e, appUrl)).join("\n");
  const unsubscribeUrl = `${appUrl}/profile?tab=notifications`;

  return `
<!DOCTYPE html>
<html>
<head><meta charset="utf-8" /></head>
<body style="background-color:#f6f9fc;font-family:ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:0;">
  <div style="background-color:#ffffff;padding:0;border-radius:8px;margin:40px auto;max-width:560px;overflow:hidden;">
    <div style="background-color:#f59e0b;padding:32px 40px 24px;text-align:center;">
      <div style="font-size:13px;font-weight:700;color:#0f172a;text-transform:uppercase;letter-spacing:0.12em;margin:0 0 8px;">Family Events</div>
      <div style="font-size:26px;font-weight:700;color:#0f172a;margin:0 0 6px;">Your Weekly Digest</div>
      <div style="font-size:15px;color:#422006;margin:0;">${eventCount} events this week in ${cityName}</div>
    </div>
    <hr style="border-color:#e6e6e6;margin:0;" />
    <div style="font-size:16px;color:#1a1a1a;padding:24px 40px 0;margin:0;">Hi ${username},</div>
    <div style="font-size:15px;color:#475569;padding:8px 40px 16px;margin:0;">Here are the upcoming family-friendly events near you this week.</div>
    ${eventsHtml}
    <div style="text-align:center;padding:24px 40px 32px;">
      <a href="${escapeHtml(appUrl)}" style="background-color:#f59e0b;color:#0f172a;padding:12px 24px;border-radius:10px;font-size:15px;font-weight:700;text-decoration:none;display:inline-block;">Browse All Events</a>
    </div>
    <hr style="border-color:#e6e6e6;margin:0;" />
    <div style="font-size:12px;color:#94a3b8;padding:20px 40px;margin:0;text-align:center;">
      You're receiving this because you have digest emails enabled.
      <a href="${escapeHtml(unsubscribeUrl)}" style="color:#64748b;text-decoration:underline;">Manage preferences</a>
    </div>
  </div>
</body>
</html>`.trim();
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

serveServiceRoleJson(
  { functionName: "send-weekly-digest" },
  async ({ request, supabase }) => {
    const cronCtx = cronRunContextFromRequest(request);

    // 1. Query digest opt-ins, then load profiles with cities. PostgREST cannot
    // embed user_profiles through auth.users, so keep this as two explicit reads.
    const { data: preferences, error: preferencesError } = await supabase
      .from("user_notification_preferences")
      .select("user_id")
      .eq("digest_email", true);

    if (preferencesError) {
      await logCronRunEvent(supabase, cronCtx, "error", "Failed to query digest users", {
        error: preferencesError.message,
      });
      throw preferencesError;
    }

    const preferenceRows = (preferences ?? []) as DigestPreference[];
    const userIds = [...new Set(preferenceRows.map((row) => row.user_id).filter(Boolean))];

    if (userIds.length === 0) {
      await logCronRunEvent(supabase, cronCtx, "log", "No digest users found", {});
      return { ok: true, sent: 0, skipped: 0, failed: 0 };
    }

    type ProfileRow = {
      id: string;
      email: string | null;
      display_name: string | null;
      city_preference_id: string | null;
      cities: { id: string; name: string } | null;
    };

    const { data: profiles, error: profilesError } = await supabase
      .from("user_profiles")
      .select("id, email, display_name, city_preference_id, cities!inner(id, name)")
      .in("id", userIds);

    if (profilesError) {
      await logCronRunEvent(supabase, cronCtx, "error", "Failed to query digest profiles", {
        error: profilesError.message,
      });
      throw profilesError;
    }

    const profilesById = new Map<string, ProfileRow>();
    for (const profile of (profiles ?? []) as unknown as ProfileRow[]) {
      profilesById.set(profile.id, profile);
    }

    const digestUsers: DigestUser[] = [];
    for (const row of preferenceRows) {
      const profile = profilesById.get(row.user_id);
      if (!profile?.email || !profile.cities) continue;
      digestUsers.push({
        user_id: row.user_id,
        email: profile.email,
        display_name: profile.display_name,
        city_id: profile.cities.id,
        city_name: profile.cities.name,
      });
    }

    if (digestUsers.length === 0) {
      await logCronRunEvent(supabase, cronCtx, "log", "No digest users found", {});
      return { ok: true, sent: 0, skipped: 0, failed: 0 };
    }

    // 2. Group users by city to avoid duplicate event queries
    const usersByCity = new Map<string, DigestUser[]>();
    for (const user of digestUsers) {
      const group = usersByCity.get(user.city_id) ?? [];
      group.push(user);
      usersByCity.set(user.city_id, group);
    }

    // 3. For each city, query upcoming published events for next 7 days
    const now = new Date();
    const weekFromNow = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);

    const eventsByCity = new Map<string, DigestEvent[]>();
    for (const cityId of usersByCity.keys()) {
      const { data: events, error: eventsError } = await supabase.rpc("search_events", {
        p_city_id: cityId,
        p_date_from: now.toISOString(),
        p_date_to: weekFromNow.toISOString(),
        p_status: "published",
        p_limit: MAX_EVENTS_PER_DIGEST,
      });

      if (eventsError) {
        logEdgeEvent("warn", "Failed to query events for city", {
          function: "send-weekly-digest",
          city_id: cityId,
          error: eventsError.message,
        });
        continue;
      }

      if (events && events.length > 0) {
        eventsByCity.set(cityId, events as DigestEvent[]);
      }
    }

    // 4. Send emails via Resend
    const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? "";
    const resendFrom = Deno.env.get("RESEND_FROM") ?? "Family Events <onboarding@resend.dev>";
    const appUrl = (Deno.env.get("APP_URL") ?? "https://family-events.up.railway.app").replace(/\/$/, "");

    if (!resendApiKey) {
      const totalUsers = digestUsers.length;
      const citiesWithEvents = eventsByCity.size;
      logEdgeEvent("warn", "send-weekly-digest: RESEND_API_KEY not configured; would have sent digests", {
        function: "send-weekly-digest",
        total_users: totalUsers,
        cities_with_events: citiesWithEvents,
      });
      await logCronRunEvent(supabase, cronCtx, "log", "Dry run (no RESEND_API_KEY)", {
        total_users: totalUsers,
        cities_with_events: citiesWithEvents,
      });
      return { ok: true, sent: 0, skipped: totalUsers, failed: 0, dev: true };
    }

    let sent = 0;
    let skipped = 0;
    let failed = 0;

    // Process in batches to rate-limit Resend API calls
    const allUsers = [...digestUsers];
    for (let i = 0; i < allUsers.length; i += BATCH_SIZE) {
      const batch = allUsers.slice(i, i + BATCH_SIZE);

      for (const user of batch) {
        const events = eventsByCity.get(user.city_id);
        if (!events || events.length === 0) {
          skipped++;
          continue;
        }

        const html = renderDigestHtml(user, events, appUrl);
        const subject = `${events.length} family events this week in ${user.city_name}`;

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
              subject,
              html,
            }),
            signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
          });

          if (response.ok) {
            sent++;
          } else {
            const body = await response.text().catch(() => "");
            logEdgeEvent("warn", "send-weekly-digest: Resend rejected email", {
              function: "send-weekly-digest",
              to: user.email,
              status: response.status,
              body: body.slice(0, 300),
            });
            failed++;
          }
        } catch (err) {
          logEdgeEvent("warn", "send-weekly-digest: failed to send", {
            function: "send-weekly-digest",
            to: user.email,
            error: err instanceof Error ? err.message : String(err),
          });
          failed++;
        }
      }

      // Rate-limit: pause between batches (skip after last batch)
      if (i + BATCH_SIZE < allUsers.length) {
        await sleep(BATCH_DELAY_MS);
      }
    }

    const summary = { ok: true, sent, skipped, failed, total: allUsers.length };
    await logCronRunEvent(supabase, cronCtx, "log", "Weekly digest run complete", summary);
    logEdgeEvent("log", "send-weekly-digest: complete", {
      function: "send-weekly-digest",
      ...summary,
    });

    return summary;
  },
);
