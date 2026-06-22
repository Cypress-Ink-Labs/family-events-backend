import "@supabase/functions-js/edge-runtime.d.ts"
import { serveServiceRoleJson, serviceRoleJsonError } from "../_shared/service-role-handler.ts"
import { escapeHtml } from "../_shared/html.ts"
import { logEdgeEvent } from "../_shared/logger.ts"
import { cronRunContextFromRequest, logCronRunEvent } from "../_shared/cron-run-log.ts"
import { sendResendEmail } from "../_shared/resend.ts"
import { sendTelegramMessage } from "../_shared/telegram.ts"

// send-weekly-digest
// ----------------------------------------------------------------
// Cron-triggered edge function that sends branded weekly digest emails
// to users who have digest_email=true. For each user, calls the
// plan_events_for_user_range RPC (Phase 2) to get personalized ranked
// events for the upcoming weekend across the user's preferred cities.
// Skips users whose RPC returns no events. Sends via Resend API.
// Rate-limits with small delays between batches.

const BATCH_SIZE = 5
const BATCH_DELAY_MS = 500
const MAX_EVENTS_PER_DIGEST = 5
// Max per-user ranking lookups (RPC + event fetch) in flight at once, so a large
// recipient list doesn't monopolize the cron in a serial pre-send phase.
const LOOKUP_CONCURRENCY = 5

interface DigestUser {
  user_id: string
  email: string
  display_name: string | null
  city_id: string
  city_name: string
  // Primary city centroid — used as the reference point for distance scoring.
  // Distance is measured from the user's city_preference_id city (the joined cities row).
  // null when the city has no centroid; the RPC falls back to a neutral 0.50 score.
  lat: number | null
  lng: number | null
  child_age: number | null
  digest_email: boolean
  digest_telegram: boolean
  telegram_chat_id: string | null
}

interface DigestPreference {
  user_id: string
  digest_email: boolean
  digest_telegram: boolean
  telegram_chat_id: string | null
}

interface DigestEvent {
  id: string
  title: string
  start_datetime: string
  venue_name: string | null
  address: string | null
  is_free: boolean
  price: number | null
  // events.images is a jsonb array; elements are URL strings in practice, but
  // tolerate { url } objects too in case enrichment shape changes.
  images: Array<string | { url?: string }> | null
  explanation?: string
}

// Rows returned by plan_events_for_user_range RPC
interface RankedEventRow {
  event_id: string
  score: number
  distance_score: number | null
  weather_score: number | null
  age_score: number | null
  history_affinity: number | null
  family_fit_score: number | null
  timing_score: number | null
  novelty_score: number | null
  budget_score: number | null
  distance_km: number | null
  start_datetime: string
  city_id: string
}

function firstImageUrl(event: DigestEvent): string | undefined {
  const first = event.images?.[0]
  if (typeof first === "string") return first
  if (first && typeof first === "object") return first.url
  return undefined
}

// Some source events carry HTML markup in title/venue/address (e.g.
// "<p>Cajun Field</p>"). Strip tags and collapse whitespace before escaping.
function stripTags(value: string): string {
  return value
    .replace(/<[^>]*>/g, " ")
    .replace(/\s+/g, " ")
    .trim()
}

function formatPrice(event: DigestEvent): string {
  if (event.is_free) return "Free"
  if (event.price != null) return `$${Number(event.price).toFixed(2)}`
  return ""
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
} as const

const FONT_SANS = `'DM Sans', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif`
const FONT_DISPLAY = `'Fraunces', ui-serif, Georgia, 'Times New Roman', serif`
const FONT_EDITORIAL = `'Newsreader', ui-serif, Georgia, 'Times New Roman', serif`
const FONT_MONO = `'Geist Mono', ui-monospace, 'SF Mono', Menlo, Consolas, monospace`

const FONTS_HREF =
  "https://fonts.googleapis.com/css2?family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,700&family=Fraunces:opsz,wght@9..144,500;9..144,600;9..144,700&family=Newsreader:opsz,wght@6..72,400;6..72,500&family=Geist+Mono:wght@400;500&display=swap"

function splitDateTime(isoDate: string): { date: string; time: string } {
  try {
    const d = new Date(isoDate)
    const date = d.toLocaleDateString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
    })
    const time = d.toLocaleTimeString("en-US", {
      hour: "numeric",
      minute: "2-digit",
    })
    return { date, time }
  } catch {
    return { date: isoDate, time: "" }
  }
}

function renderPricePill(event: DigestEvent): string {
  const price = formatPrice(event)
  if (!price) return ""
  const isFree = event.is_free
  const fill = isFree ? THEME.successSoft : THEME.peachSoft
  const color = isFree ? THEME.successText : THEME.peachDeep
  return `<span style="display:inline-block;background:${fill};color:${color};font-family:${FONT_MONO};font-size:11px;font-weight:500;letter-spacing:0.04em;text-transform:uppercase;padding:3px 9px;border-radius:9999px;">${escapeHtml(price)}</span>`
}

// Factor name → friendly label mapping (in weight/priority order for tie-breaking)
const FACTOR_LABELS: Array<[keyof RankedEventRow, string]> = [
  ["distance_score", "nearby"],
  ["weather_score", "weather fit"],
  ["age_score", "great age match"],
  ["history_affinity", "matches your interests"],
  ["family_fit_score", "family-friendly"],
  ["timing_score", "perfect weekend timing"],
  ["novelty_score", "newly added"],
  ["budget_score", "budget-friendly"],
]

// Neutral default threshold — factors at or below this add no meaningful signal
const NEUTRAL_THRESHOLD = 0.5

// Build a human-readable explanation string from RPC score factors.
// Returns the top 2 factors (by value, ignoring neutral-or-below) joined with " · ".
function buildExplanation(row: RankedEventRow): string | undefined {
  const candidates: Array<{ label: string; value: number; order: number }> = []
  for (let i = 0; i < FACTOR_LABELS.length; i++) {
    const [key, label] = FACTOR_LABELS[i]
    const val = row[key] as number | null
    if (val != null && val > NEUTRAL_THRESHOLD) {
      candidates.push({ label, value: val, order: i })
    }
  }
  if (candidates.length === 0) return undefined
  // Sort descending by value; ties broken by original weight order (lower index = higher priority)
  candidates.sort((a, b) => b.value - a.value || a.order - b.order)
  const top2 = candidates.slice(0, 2).map((c) => c.label)
  return top2.join(" · ")
}

function renderEventCardHtml(event: DigestEvent, appUrl: string): string {
  const eventUrl = `${appUrl}/events/${event.id}`
  const thumbnail = firstImageUrl(event)
  const title = stripTags(event.title)
  const location = stripTags(event.venue_name || event.address || "")
  const { date, time } = splitDateTime(event.start_datetime)
  const initial = escapeHtml((title[0] || "•").toUpperCase())

  const imageCell = thumbnail
    ? `<img src="${escapeHtml(thumbnail)}" width="92" height="92" alt=""
           style="width:92px;height:92px;border-radius:12px;object-fit:cover;display:block;border:1px solid ${THEME.border};" />`
    : `<div style="width:92px;height:92px;border-radius:12px;background:${THEME.surfaceAlt};border:1px solid ${THEME.border};text-align:center;line-height:92px;font-family:${FONT_DISPLAY};font-size:34px;font-weight:600;color:${THEME.violet};">${initial}</div>`

  const metaLine = [
    `<span style="font-family:${FONT_MONO};font-size:12px;color:${THEME.textMuted};">${escapeHtml(date)}${time ? ` · ${escapeHtml(time)}` : ""}</span>`,
    renderPricePill(event),
  ]
    .filter(Boolean)
    .join(`<span style="color:${THEME.border};">&nbsp;&nbsp;</span>`)

  const explanationHtml = event.explanation
    ? `<div style="font-family:${FONT_SANS};font-size:12px;color:${THEME.textMuted};margin-top:5px;font-style:italic;">${escapeHtml(event.explanation)}</div>`
    : ""

  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 14px;">
      <tr>
        <td style="background:${THEME.surface};border:1px solid ${THEME.border};border-radius:16px;padding:16px;box-shadow:0 1px 2px rgba(28,24,40,0.04);">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">
            <tr>
              <td width="92" valign="top" style="padding-right:16px;">${imageCell}</td>
              <td valign="top">
                <a href="${escapeHtml(eventUrl)}" style="font-family:${FONT_DISPLAY};font-size:18px;line-height:1.25;font-weight:600;color:${THEME.textPrimary};text-decoration:none;">${escapeHtml(title)}</a>
                <div style="margin-top:8px;">${metaLine}</div>
                ${
                  location
                    ? `<div style="font-family:${FONT_SANS};font-size:13px;color:${THEME.blue};margin-top:6px;">&#9679;&nbsp;${escapeHtml(location)}</div>`
                    : ""
                }
                ${explanationHtml}
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>`
}

// Renders the full branded email as a single HTML string. We send raw `html`
// (not a Resend hosted template) because the events block routinely exceeds
// Resend's 2,000-char-per-template-variable limit. USERNAME/CITY_NAME are
// escaped; event-card fields are escaped inside renderEventCardHtml.
function renderDigestHtml(user: DigestUser, events: DigestEvent[], appUrl: string): string {
  const username = escapeHtml(user.display_name || "there")
  const cityName = escapeHtml(user.city_name)
  const eventCount = String(events.length)
  const eventLabel = events.length === 1 ? "event" : "events"
  const eventsHtml = events.map((e) => renderEventCardHtml(e, appUrl)).join("\n")
  const unsubscribeUrl = `${appUrl}/profile?tab=notifications`
  const logoUrl = `${appUrl}/brand/family-events-logo.png`

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
</html>`.trim()
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

// Formats a short Telegram HTML message for the digest.
// Uses Telegram's HTML subset: <b>, <a href="...">, entity escaping.
// Renders the top events as a compact bulleted list.
function formatDigestTelegram(user: DigestUser, events: DigestEvent[], appUrl: string): string {
  const username = escapeHtml(user.display_name || "there")
  const cityName = escapeHtml(user.city_name)
  const lines: string[] = []

  lines.push(`<b>Hi ${username}, your weekend in ${cityName}!</b>`)
  lines.push("")

  for (const event of events) {
    const title = escapeHtml(stripTags(event.title))
    const eventUrl = `${appUrl}/events/${event.id}`
    const location = stripTags(event.venue_name || event.address || "")
    const { date } = splitDateTime(event.start_datetime)
    const price = formatPrice(event)

    const meta: string[] = [escapeHtml(date)]
    if (location) meta.push(escapeHtml(location))
    if (price) meta.push(escapeHtml(price))

    lines.push(`• <a href="${escapeHtml(eventUrl)}">${title}</a>`)
    lines.push(`  ${meta.join(" · ")}`)
    if (event.explanation) {
      lines.push(`  <i>${escapeHtml(event.explanation)}</i>`)
    }
  }

  lines.push("")
  lines.push(`<a href="${escapeHtml(appUrl)}">→ Browse all events</a>`)

  return lines.join("\n")
}

serveServiceRoleJson({ functionName: "send-weekly-digest" }, async ({ request, supabase }) => {
  const cronCtx = cronRunContextFromRequest(request)

  // Optional single-recipient override for manual/test runs:
  //   POST { "test_email": "you@example.com" }
  // When set, the run is scoped to that one recipient (must still be a digest
  // opt-in). Cron invocations send no body, so this is null in production.
  let testEmail: string | null = null
  try {
    const body = (await request.json().catch(() => null)) as { test_email?: unknown } | null
    const raw =
      body && typeof body.test_email === "string" ? body.test_email.trim().toLowerCase() : ""
    testEmail = raw.length > 0 ? raw : null
  } catch {
    // no/invalid body — treat as a normal full run
  }

  // 1. Query digest opt-ins, then load profiles with cities. PostgREST cannot
  // embed user_profiles through auth.users, so keep this as two explicit reads.
  // Include users opted in to EITHER email or Telegram.
  const { data: preferences, error: preferencesError } = await supabase
    .from("user_notification_preferences")
    .select("user_id, digest_email, digest_telegram, telegram_chat_id")
    .or("digest_email.eq.true,digest_telegram.eq.true")

  if (preferencesError) {
    await logCronRunEvent(supabase, cronCtx, "error", "Failed to query digest users", {
      error: preferencesError.message,
    })
    throw preferencesError
  }

  const preferenceRows = (preferences ?? []) as DigestPreference[]
  const userIds = [...new Set(preferenceRows.map((row) => row.user_id).filter(Boolean))]

  if (userIds.length === 0) {
    await logCronRunEvent(supabase, cronCtx, "log", "No digest users found", {})
    return { ok: true, sent: 0, skipped: 0, failed: 0 }
  }

  type ProfileRow = {
    id: string
    email: string | null
    display_name: string | null
    city_preference_id: string | null
    child_age: number | null
    cities: { id: string; name: string; latitude: number | null; longitude: number | null } | null
  }

  const { data: profiles, error: profilesError } = await supabase
    .from("user_profiles")
    .select(
      "id, email, display_name, city_preference_id, child_age, cities!inner(id, name, latitude, longitude)"
    )
    .in("id", userIds)

  if (profilesError) {
    await logCronRunEvent(supabase, cronCtx, "error", "Failed to query digest profiles", {
      error: profilesError.message,
    })
    throw profilesError
  }

  const profilesById = new Map<string, ProfileRow>()
  for (const profile of (profiles ?? []) as unknown as ProfileRow[]) {
    profilesById.set(profile.id, profile)
  }

  const digestUsers: DigestUser[] = []
  for (const row of preferenceRows) {
    const profile = profilesById.get(row.user_id)
    if (!profile?.email || !profile.cities) continue
    digestUsers.push({
      user_id: row.user_id,
      email: profile.email,
      display_name: profile.display_name,
      city_id: profile.cities.id,
      city_name: profile.cities.name,
      lat: profile.cities.latitude ?? null,
      lng: profile.cities.longitude ?? null,
      child_age: profile.child_age ?? null,
      digest_email: row.digest_email,
      digest_telegram: row.digest_telegram,
      telegram_chat_id: row.telegram_chat_id,
    })
  }

  if (digestUsers.length === 0) {
    await logCronRunEvent(supabase, cronCtx, "log", "No digest users found", {})
    return { ok: true, sent: 0, skipped: 0, failed: 0 }
  }

  // 1b. If a test_email override is set, scope the run to that one recipient.
  let targetedUsers = digestUsers
  if (testEmail) {
    targetedUsers = digestUsers.filter((u) => u.email.toLowerCase() === testEmail)
    if (targetedUsers.length === 0) {
      await logCronRunEvent(supabase, cronCtx, "log", "Test email not among digest opt-ins", {
        test_email: testEmail,
      })
      return {
        ok: true,
        sent: 0,
        skipped: 0,
        failed: 0,
        test_email: testEmail,
        note: "no matching digest user (must have digest_email=true)",
      }
    }
  }

  // 1c. Batch-load preferred cities for all targeted users.
  // Fallback for users with no rows: their primary city_id.
  const targetedUserIds = targetedUsers.map((u) => u.user_id)
  const { data: prefCityRows, error: prefCityError } = await supabase
    .from("user_preferred_cities")
    .select("user_id, city_id")
    .in("user_id", targetedUserIds)

  if (prefCityError) {
    logEdgeEvent("warn", "send-weekly-digest: failed to load preferred cities; using primary", {
      function: "send-weekly-digest",
      error: prefCityError.message,
    })
  }

  // Build map: user_id → city_id[]
  const prefCityMap = new Map<string, string[]>()
  for (const row of (prefCityRows ?? []) as Array<{ user_id: string; city_id: string }>) {
    const list = prefCityMap.get(row.user_id) ?? []
    list.push(row.city_id)
    prefCityMap.set(row.user_id, list)
  }

  // 2. Compute the upcoming weekend window (UTC).
  // UTC approximation — the RPC's timing_score refines local-time fit.
  const now = new Date()
  const day = now.getUTCDay() // 0=Sun..6=Sat
  const fridayOffset = day === 0 ? -2 : day === 6 ? -1 : 5 - day
  const friday = new Date(now)
  friday.setUTCDate(now.getUTCDate() + fridayOffset)
  friday.setUTCHours(0, 0, 0, 0)
  const sunday = new Date(friday)
  sunday.setUTCDate(friday.getUTCDate() + 2)
  sunday.setUTCHours(23, 59, 59, 999)
  // Don't recommend events already in the past
  const windowFrom = new Date(Math.max(now.getTime(), friday.getTime())).toISOString()
  const windowTo = sunday.toISOString()

  // 3. Per-user (bounded concurrency): rank → fetch event details → build DigestEvent[].
  const eventsByUser = new Map<string, DigestEvent[]>()

  async function buildUserDigestEvents(user: DigestUser): Promise<void> {
    const cityIds = prefCityMap.get(user.user_id) ?? [user.city_id]

    const { data: rankedRows, error: rpcError } = await supabase.rpc("plan_events_for_user_range", {
      p_user_id: user.user_id,
      p_date_from: windowFrom,
      p_date_to: windowTo,
      p_city_ids: cityIds,
      p_kid_age: user.child_age,
      p_weather_fit: "neutral",
      p_limit: MAX_EVENTS_PER_DIGEST,
      // Distance is measured from the user's primary city centroid (city_preference_id → cities join).
      // null when the city has no centroid; the RPC defaults to a neutral 0.50 distance score.
      p_lat: user.lat,
      p_lng: user.lng,
    })

    if (rpcError) {
      logEdgeEvent("warn", "send-weekly-digest: plan_events_for_user_range failed", {
        function: "send-weekly-digest",
        user_id: user.user_id,
        error: rpcError.message,
      })
      return
    }

    const ranked = (rankedRows ?? []) as RankedEventRow[]
    if (ranked.length === 0) return

    const eventIds = ranked.map((r) => r.event_id)

    const { data: eventRows, error: eventsError } = await supabase
      .from("events")
      .select("id, title, start_datetime, venue_name, address, is_free, price, images")
      .in("id", eventIds)

    if (eventsError) {
      logEdgeEvent("warn", "send-weekly-digest: failed to fetch event details", {
        function: "send-weekly-digest",
        user_id: user.user_id,
        error: eventsError.message,
      })
      return
    }

    // Build a lookup map by event_id, then reassemble in ranked order
    const eventMap = new Map<string, DigestEvent>()
    for (const row of (eventRows ?? []) as DigestEvent[]) {
      eventMap.set(row.id, row)
    }

    const digestEvents: DigestEvent[] = []
    for (const rankedRow of ranked) {
      const ev = eventMap.get(rankedRow.event_id)
      if (!ev) continue
      const explanation = buildExplanation(rankedRow)
      digestEvents.push({ ...ev, explanation })
    }

    if (digestEvents.length > 0) {
      eventsByUser.set(user.user_id, digestEvents)
    }
  }

  // Process users in bounded-concurrency chunks so the lookup phase doesn't run
  // fully serial across a large recipient list (Map writes are safe — single-threaded).
  for (let i = 0; i < targetedUsers.length; i += LOOKUP_CONCURRENCY) {
    const chunk = targetedUsers.slice(i, i + LOOKUP_CONCURRENCY)
    await Promise.all(chunk.map((u) => buildUserDigestEvents(u)))
  }

  // 4. Read API keys / secrets
  const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? ""
  const resendFrom = Deno.env.get("RESEND_FROM") ?? "Family Events <onboarding@resend.dev>"
  const appUrl = (Deno.env.get("APP_URL") ?? "https://family-events.up.railway.app").replace(
    /\/$/,
    ""
  )

  // Telegram bot token: try vault first (mirrors send-push pattern), then env.
  let botToken = ""
  try {
    const { data: secrets } = await supabase
      .from("vault.decrypted_secrets" as "push_subscriptions") // cast to satisfy type
      .select("name, decrypted_secret")
      .in("name", ["telegram_bot_token"])

    if (secrets) {
      for (const s of secrets as Array<{ name: string; decrypted_secret: string }>) {
        if (s.name === "telegram_bot_token") botToken = s.decrypted_secret
      }
    }
  } catch {
    // Vault may not be available in local dev
  }
  if (!botToken) botToken = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? ""

  if (!resendApiKey) {
    const totalUsers = digestUsers.length
    const usersWithEvents = eventsByUser.size
    logEdgeEvent(
      "warn",
      "send-weekly-digest: RESEND_API_KEY not configured; would have sent digests",
      {
        function: "send-weekly-digest",
        total_users: totalUsers,
        users_with_events: usersWithEvents,
      }
    )
    await logCronRunEvent(supabase, cronCtx, "log", "Dry run (no RESEND_API_KEY)", {
      total_users: totalUsers,
      users_with_events: usersWithEvents,
    })
    return { ok: true, sent: 0, skipped: totalUsers, failed: 0, dev: true }
  }

  let sent = 0
  let skipped = 0
  let failed = 0
  let telegramSent = 0
  let telegramSkipped = 0

  // Process in batches to rate-limit API calls
  const allUsers = [...targetedUsers]
  for (let i = 0; i < allUsers.length; i += BATCH_SIZE) {
    const batch = allUsers.slice(i, i + BATCH_SIZE)

    for (const user of batch) {
      const events = eventsByUser.get(user.user_id)
      if (!events || events.length === 0) {
        skipped++
        continue
      }

      // ── Email via Resend (only if opted in) ─────────────────────────────────
      if (user.digest_email) {
        const html = renderDigestHtml(user, events, appUrl)
        const subject = `${events.length} family picks for your weekend`

        try {
          const result = await sendResendEmail(resendApiKey, {
            from: resendFrom,
            to: [user.email],
            subject,
            html,
          })

          if (result.ok) {
            sent++
          } else {
            logEdgeEvent("warn", "send-weekly-digest: Resend rejected email", {
              function: "send-weekly-digest",
              to: user.email,
              status: result.status,
              body: result.errorBody,
            })
            failed++
          }
        } catch (err) {
          logEdgeEvent("warn", "send-weekly-digest: failed to send email", {
            function: "send-weekly-digest",
            to: user.email,
            error: err instanceof Error ? err.message : String(err),
          })
          failed++
        }
      }

      // ── Telegram ─────────────────────────────────────────────────────────────
      if (user.digest_telegram) {
        if (!user.telegram_chat_id || !botToken) {
          logEdgeEvent(
            "warn",
            "send-weekly-digest: skipping telegram digest (no chat_id or token)",
            {
              function: "send-weekly-digest",
              user_id: user.user_id,
              has_chat_id: !!user.telegram_chat_id,
              has_token: !!botToken,
            }
          )
          telegramSkipped++
        } else {
          const text = formatDigestTelegram(user, events, appUrl)
          const tgResult = await sendTelegramMessage(botToken, user.telegram_chat_id, text)
          if (tgResult.ok) {
            telegramSent++
          } else {
            logEdgeEvent("warn", "send-weekly-digest: Telegram send failed", {
              function: "send-weekly-digest",
              user_id: user.user_id,
              error: tgResult.error,
            })
            telegramSkipped++
          }
        }
      }
    }

    // Rate-limit: pause between batches (skip after last batch)
    if (i + BATCH_SIZE < allUsers.length) {
      await sleep(BATCH_DELAY_MS)
    }
  }

  const summary = {
    ok: true,
    sent,
    skipped,
    failed,
    total: allUsers.length,
    telegram_sent: telegramSent,
    telegram_skipped: telegramSkipped,
  }
  await logCronRunEvent(supabase, cronCtx, "log", "Weekly digest run complete", summary)
  logEdgeEvent("log", "send-weekly-digest: complete", {
    function: "send-weekly-digest",
    ...summary,
  })

  return summary
})
