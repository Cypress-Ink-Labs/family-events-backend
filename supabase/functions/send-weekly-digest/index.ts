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

function formatPrice(event: DigestEvent): string {
  if (event.is_free) return "Free";
  if (event.price != null) return `$${Number(event.price).toFixed(2)}`;
  return "";
}

// ── Dusk-Meadow theme tokens (mirrors packages/design-system) ─────────────────
// Inlined here because edge functions can't import the design-system package.
const THEME = {
  bg: "#F5F3FC", // lavender-white bedrock
  surface: "#FDFCFF", // cards
  surfaceAlt: "#F2EEFB", // image placeholder fill
  textPrimary: "#1C1828", // deep violet-plum
  textMuted: "#6B6278", // secondary text
  border: "#EAE4F6", // hairline borders
  violet: "#7B5CC8", // brand anchor
  violetDeep: "#5E42A6", // gradient end / strong links
  peach: "#E89060", // action color (CTA)
  peachDeep: "#C2703B", // paid-price text
  peachSoft: "#FBEDE3", // paid-price pill fill
  blue: "#5A7EA8", // location
  gold: "#D4AA28", // kid affordances
  successText: "#2E7D5B", // free-price text
  successSoft: "#E6F2EC", // free-price pill fill
} as const;

const FONT_SANS = `'DM Sans', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif`;
const FONT_DISPLAY = `'Fraunces', ui-serif, Georgia, 'Times New Roman', serif`;
const FONT_EDITORIAL = `'Newsreader', ui-serif, Georgia, 'Times New Roman', serif`;
const FONT_MONO = `'Geist Mono', ui-monospace, 'SF Mono', Menlo, Consolas, monospace`;

const FONTS_HREF =
  "https://fonts.googleapis.com/css2?family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,700&family=Fraunces:opsz,wght@9..144,500;9..144,600;9..144,700&family=Newsreader:opsz,wght@6..72,400;6..72,500&family=Geist+Mono:wght@400;500&display=swap";

function splitDateTime(isoDate: string): { date: string; time: string } {
  try {
    const d = new Date(isoDate);
    const date = d.toLocaleDateString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
    });
    const time = d.toLocaleTimeString("en-US", {
      hour: "numeric",
      minute: "2-digit",
    });
    return { date, time };
  } catch {
    return { date: isoDate, time: "" };
  }
}

function renderPricePill(event: DigestEvent): string {
  const price = formatPrice(event);
  if (!price) return "";
  const isFree = event.is_free;
  const fill = isFree ? THEME.successSoft : THEME.peachSoft;
  const color = isFree ? THEME.successText : THEME.peachDeep;
  return `<span style="display:inline-block;background:${fill};color:${color};font-family:${FONT_MONO};font-size:11px;font-weight:500;letter-spacing:0.04em;text-transform:uppercase;padding:3px 9px;border-radius:9999px;">${escapeHtml(price)}</span>`;
}

function renderEventCardHtml(event: DigestEvent, appUrl: string): string {
  const eventUrl = `${appUrl}/events/${event.id}`;
  const thumbnail = event.images?.[0]?.url;
  const location = event.venue_name || event.address || "";
  const { date, time } = splitDateTime(event.start_datetime);
  const initial = escapeHtml((event.title.trim()[0] || "•").toUpperCase());

  const imageCell = thumbnail
    ? `<img src="${escapeHtml(thumbnail)}" width="92" height="92" alt=""
           style="width:92px;height:92px;border-radius:12px;object-fit:cover;display:block;border:1px solid ${THEME.border};" />`
    : `<div style="width:92px;height:92px;border-radius:12px;background:${THEME.surfaceAlt};border:1px solid ${THEME.border};text-align:center;line-height:92px;font-family:${FONT_DISPLAY};font-size:34px;font-weight:600;color:${THEME.violet};">${initial}</div>`;

  const metaLine = [
    `<span style="font-family:${FONT_MONO};font-size:12px;color:${THEME.textMuted};">${escapeHtml(date)}${time ? ` · ${escapeHtml(time)}` : ""}</span>`,
    renderPricePill(event),
  ]
    .filter(Boolean)
    .join(`<span style="color:${THEME.border};">&nbsp;&nbsp;</span>`);

  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 14px;">
      <tr>
        <td style="background:${THEME.surface};border:1px solid ${THEME.border};border-radius:16px;padding:16px;box-shadow:0 1px 2px rgba(28,24,40,0.04);">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">
            <tr>
              <td width="92" valign="top" style="padding-right:16px;">${imageCell}</td>
              <td valign="top">
                <a href="${escapeHtml(eventUrl)}" style="font-family:${FONT_DISPLAY};font-size:18px;line-height:1.25;font-weight:600;color:${THEME.textPrimary};text-decoration:none;">${escapeHtml(event.title)}</a>
                <div style="margin-top:8px;">${metaLine}</div>
                ${
    location
      ? `<div style="font-family:${FONT_SANS};font-size:13px;color:${THEME.blue};margin-top:6px;">&#9679;&nbsp;${escapeHtml(location)}</div>`
      : ""
  }
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>`;
}

// Renders the full branded email as a single HTML string. We send raw `html`
// (not a Resend hosted template) because the events block routinely exceeds
// Resend's 2,000-char-per-template-variable limit. USERNAME/CITY_NAME are
// escaped; event-card fields are escaped inside renderEventCardHtml.
function renderDigestHtml(
  user: DigestUser,
  events: DigestEvent[],
  appUrl: string,
): string {
  const username = escapeHtml(user.display_name || "there");
  const cityName = escapeHtml(user.city_name);
  const eventCount = String(events.length);
  const eventLabel = events.length === 1 ? "event" : "events";
  const eventsHtml = events.map((e) => renderEventCardHtml(e, appUrl)).join("\n");
  const unsubscribeUrl = `${appUrl}/profile?tab=notifications`;
  const logoUrl = `${appUrl}/brand/family-events-logo.png`;

  return `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="light" />
  <meta name="supported-color-schemes" content="light" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="${FONTS_HREF}" rel="stylesheet" />
  <style>
    body { margin:0; padding:0; background:${THEME.bg}; -webkit-font-smoothing:antialiased; }
    a { text-decoration:none; }
    @media only screen and (max-width:600px) {
      .fe-shell { width:100% !important; border-radius:0 !important; }
      .fe-pad { padding-left:20px !important; padding-right:20px !important; }
    }
  </style>
</head>
<body style="margin:0;padding:0;background:${THEME.bg};font-family:${FONT_SANS};">
  <span style="display:none;visibility:hidden;opacity:0;height:0;width:0;overflow:hidden;mso-hide:all;">${eventCount} family events this week in ${cityName}</span>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${THEME.bg};">
    <tr>
      <td align="center" style="padding:32px 12px;">
        <table role="presentation" class="fe-shell" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background:${THEME.surface};border-radius:24px;overflow:hidden;box-shadow:0 12px 32px rgba(28,24,40,0.10);">

          <!-- Header -->
          <tr>
            <td style="background:${THEME.violet};background-image:linear-gradient(135deg,${THEME.violet} 0%,${THEME.violetDeep} 100%);padding:36px 40px 32px;" class="fe-pad">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="left">
                    <img src="${escapeHtml(logoUrl)}" width="28" height="28" alt="" style="vertical-align:middle;border-radius:7px;display:inline-block;" />
                    <span style="font-family:${FONT_SANS};font-size:13px;font-weight:700;letter-spacing:0.14em;text-transform:uppercase;color:#F2ECFB;vertical-align:middle;padding-left:10px;">Family Events</span>
                  </td>
                </tr>
              </table>
              <div style="font-family:${FONT_DISPLAY};font-size:34px;line-height:1.1;font-weight:600;color:#FFFFFF;margin:22px 0 0;">Your Weekly Digest</div>
              <div style="display:inline-block;margin-top:14px;background:rgba(255,255,255,0.16);border:1px solid rgba(255,255,255,0.25);border-radius:9999px;padding:6px 14px;font-family:${FONT_MONO};font-size:12px;letter-spacing:0.03em;color:#FFFFFF;">${eventCount} ${eventLabel} this week in ${cityName}</div>
            </td>
          </tr>

          <!-- Greeting -->
          <tr>
            <td style="padding:30px 40px 6px;" class="fe-pad">
              <div style="font-family:${FONT_DISPLAY};font-size:21px;font-weight:600;color:${THEME.textPrimary};margin:0 0 8px;">Hi ${username},</div>
              <div style="font-family:${FONT_EDITORIAL};font-size:17px;line-height:1.55;color:${THEME.textMuted};margin:0;">Here are the upcoming family-friendly events near you this week — curated for your neighborhood and ready to add to the weekend plan.</div>
            </td>
          </tr>

          <!-- Event cards -->
          <tr>
            <td style="padding:22px 40px 6px;" class="fe-pad">
              ${eventsHtml}
            </td>
          </tr>

          <!-- CTA -->
          <tr>
            <td align="center" style="padding:18px 40px 36px;" class="fe-pad">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td style="background:${THEME.peach};border-radius:9999px;">
                    <a href="${escapeHtml(appUrl)}" style="display:inline-block;font-family:${FONT_SANS};font-size:15px;font-weight:700;color:#FFFFFF;padding:14px 30px;border-radius:9999px;">Browse all events &rarr;</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Footer -->
          <tr>
            <td style="background:${THEME.bg};padding:26px 40px;border-top:1px solid ${THEME.border};" class="fe-pad">
              <div style="font-family:${FONT_SANS};font-size:12px;line-height:1.6;color:${THEME.textMuted};text-align:center;margin:0;">
                You're receiving this because you enabled digest emails.<br />
                <a href="${escapeHtml(unsubscribeUrl)}" style="color:${THEME.violetDeep};font-weight:500;text-decoration:underline;">Manage preferences</a>
              </div>
              <div style="font-family:${FONT_MONO};font-size:11px;letter-spacing:0.04em;color:${THEME.textMuted};text-align:center;margin:14px 0 0;opacity:0.7;">FAMILY EVENTS · ${cityName}</div>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
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

    // Optional single-recipient override for manual/test runs:
    //   POST { "test_email": "you@example.com" }
    // When set, the run is scoped to that one recipient (must still be a digest
    // opt-in). Cron invocations send no body, so this is null in production.
    let testEmail: string | null = null;
    try {
      const body = (await request.json().catch(() => null)) as { test_email?: unknown } | null;
      const raw = body && typeof body.test_email === "string" ? body.test_email.trim().toLowerCase() : "";
      testEmail = raw.length > 0 ? raw : null;
    } catch {
      // no/invalid body — treat as a normal full run
    }

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

    // 1b. If a test_email override is set, scope the run to that one recipient.
    let targetedUsers = digestUsers;
    if (testEmail) {
      targetedUsers = digestUsers.filter((u) => u.email.toLowerCase() === testEmail);
      if (targetedUsers.length === 0) {
        await logCronRunEvent(supabase, cronCtx, "log", "Test email not among digest opt-ins", {
          test_email: testEmail,
        });
        return {
          ok: true,
          sent: 0,
          skipped: 0,
          failed: 0,
          test_email: testEmail,
          note: "no matching digest user (must have digest_email=true)",
        };
      }
    }

    // 2. Group users by city to avoid duplicate event queries
    const usersByCity = new Map<string, DigestUser[]>();
    for (const user of targetedUsers) {
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
    const allUsers = [...targetedUsers];
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
