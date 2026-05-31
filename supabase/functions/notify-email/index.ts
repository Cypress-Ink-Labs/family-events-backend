import "@supabase/functions-js/edge-runtime.d.ts"
import { requireServiceRole } from "../_shared/auth.ts"
import { captureEdgeException } from "../_shared/sentry.ts"
import { errorContext, errorMessage, logEdgeEvent } from "../_shared/logger.ts"

// notify-email
// ----------------------------------------------------------------
// Resend wrapper used by invite_request_invite and invite approval.
// Service-role-only; callers POST a tagged payload + the function
// templates + sends. Soft-failure mode: when RESEND_API_KEY is unset
// (local/dev) the function logs the would-be email and returns
// { sent: false, dev: true } so the upstream RPC's fire-and-forget
// call still succeeds and never blocks the user-facing flow.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
}

const RESEND_API_ENDPOINT = "https://api.resend.com/emails"
const RESEND_TIMEOUT_MS = 10_000

type Payload =
  | {
      kind: "admin_request"
      request_id: string
      email: string
      message: string | null
    }
  | {
      kind: "request_approved"
      email: string
      code: string
      app_url?: string
    }
  | {
      kind: "request_rejected"
      email: string
    }
  | {
      kind: "welcome"
      email: string
      username: string
    }

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

type ReadStringOptions = { required?: boolean; maxLength?: number }

function readString(
  value: Record<string, unknown>,
  key: string,
  options: ReadStringOptions & { required: true }
): string
function readString(
  value: Record<string, unknown>,
  key: string,
  options?: ReadStringOptions
): string | null
function readString(
  value: Record<string, unknown>,
  key: string,
  options: ReadStringOptions = {}
): string | null {
  const raw = value[key]
  if (raw == null) {
    if (options.required) throw new Error(`missing ${key}`)
    return null
  }
  if (typeof raw !== "string") throw new Error(`invalid ${key}`)

  const trimmed = raw.trim()
  if (options.required && !trimmed) throw new Error(`missing ${key}`)
  if (options.maxLength && trimmed.length > options.maxLength) {
    throw new Error(`invalid ${key}`)
  }

  return trimmed
}

function readOptionalString(value: Record<string, unknown>, key: string, maxLength: number): string | undefined {
  const raw = value[key]
  if (raw == null) return undefined
  if (typeof raw !== "string") throw new Error(`invalid ${key}`)
  const trimmed = raw.trim()
  if (!trimmed) return undefined
  if (trimmed.length > maxLength) throw new Error(`invalid ${key}`)
  return trimmed
}

function readNullableString(value: Record<string, unknown>, key: string, maxLength: number): string | null {
  const raw = value[key]
  if (raw == null) return null
  if (typeof raw !== "string") throw new Error(`invalid ${key}`)
  const trimmed = raw.trim()
  if (!trimmed) return null
  if (trimmed.length > maxLength) throw new Error(`invalid ${key}`)
  return trimmed
}

function assertEmail(value: string): string {
  if (value.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
    throw new Error("invalid email")
  }
  return value.toLowerCase()
}

function parsePayload(value: unknown): Payload {
  if (!isRecord(value)) throw new Error("invalid payload")
  const kind = readString(value, "kind", { required: true, maxLength: 64 })

  if (kind === "admin_request") {
    return {
      kind,
      request_id: readString(value, "request_id", { required: true, maxLength: 128 }),
      email: assertEmail(readString(value, "email", { required: true, maxLength: 320 })),
      message: readNullableString(value, "message", 2000),
    }
  }

  if (kind === "request_approved") {
    return {
      kind,
      email: assertEmail(readString(value, "email", { required: true, maxLength: 320 })),
      code: readString(value, "code", { required: true, maxLength: 64 }),
      app_url: readOptionalString(value, "app_url", 2048),
    }
  }

  if (kind === "request_rejected") {
    return {
      kind,
      email: assertEmail(readString(value, "email", { required: true, maxLength: 320 })),
    }
  }

  if (kind === "welcome") {
    return {
      kind,
      email: assertEmail(readString(value, "email", { required: true, maxLength: 320 })),
      username: readString(value, "username", { required: true, maxLength: 120 }),
    }
  }

  throw new Error("unknown kind")
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

// ── Dusk-Meadow theme tokens (mirrors packages/design-system) ─────────────────
const THEME = {
  bg: "#F5F3FC",
  surface: "#FDFCFF",
  textPrimary: "#1C1828",
  textMuted: "#6B6278",
  border: "#EAE4F6",
  violet: "#7B5CC8",
  violetDeep: "#5E42A6",
  peach: "#E89060",
} as const

const FONT_SANS = `'DM Sans', ui-sans-serif, system-ui, -apple-system, sans-serif`
const FONT_DISPLAY = `'Fraunces', ui-serif, Georgia, serif`
const FONT_EDITORIAL = `'Newsreader', ui-serif, Georgia, serif`
const FONT_MONO = `'Geist Mono', ui-monospace, 'SF Mono', monospace`

function wrapEmailShell({
  heading,
  tagline,
  bodyHtml,
  footerHtml,
  appUrl,
}: {
  heading: string
  tagline: string
  bodyHtml: string
  footerHtml: string
  appUrl: string
}): string {
  const logoUrl = `${appUrl.replace(/\/$/, "")}/brand/family-events-logo.png`
  return `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="light" />
  <link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;700&family=Fraunces:wght@500;600&display=swap" rel="stylesheet" />
</head>
<body style="margin:0;padding:0;background:${THEME.bg};font-family:${FONT_SANS};">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${THEME.bg};">
    <tr>
      <td align="center" style="padding:32px 12px;">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;background:${THEME.surface};border-radius:24px;overflow:hidden;box-shadow:0 12px 32px rgba(28,24,40,0.10);">
          <!-- Header -->
          <tr>
            <td style="background:${THEME.violet};background-image:linear-gradient(135deg,${THEME.violet} 0%,${THEME.violetDeep} 100%);padding:36px 40px 32px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="left">
                    <img src="${escapeHtml(logoUrl)}" width="28" height="28" alt="" style="vertical-align:middle;border-radius:7px;display:inline-block;" />
                    <span style="font-family:${FONT_SANS};font-size:13px;font-weight:700;letter-spacing:0.14em;text-transform:uppercase;color:#F2ECFB;vertical-align:middle;padding-left:10px;">Family Events</span>
                  </td>
                </tr>
              </table>
              <div style="font-family:${FONT_DISPLAY};font-size:34px;line-height:1.1;font-weight:600;color:#FFFFFF;margin:22px 0 0;">${escapeHtml(heading)}</div>
              <div style="display:inline-block;margin-top:14px;background:rgba(255,255,255,0.16);border:1px solid rgba(255,255,255,0.25);border-radius:9999px;padding:6px 14px;font-family:${FONT_MONO};font-size:12px;letter-spacing:0.03em;color:#FFFFFF;">${escapeHtml(tagline)}</div>
            </td>
          </tr>
          <!-- Body -->
          ${bodyHtml}
          <!-- Footer -->
          <tr>
            <td style="background:${THEME.bg};padding:26px 40px;border-top:1px solid ${THEME.border};">
              ${footerHtml}
              <div style="font-family:${FONT_MONO};font-size:11px;letter-spacing:0.04em;color:${THEME.textMuted};text-align:center;margin:14px 0 0;opacity:0.7;">FAMILY EVENTS</div>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`.trim()
}

interface RenderedEmail {
  to: string
  subject: string
  html: string
}

function renderAdminRequest(
  payload: Extract<Payload, { kind: "admin_request" }>,
  adminEmail: string,
  appUrl: string
): RenderedEmail {
  const message = payload.message?.trim()
  const linkUrl = `${appUrl.replace(/\/$/, "")}/admin/invites`

  const bodyHtml = `
    <tr>
      <td style="padding:30px 40px 6px;">
        <div style="font-family:${FONT_EDITORIAL};font-size:17px;line-height:1.55;color:${THEME.textMuted};margin:0 0 20px;">
          Someone just asked to join Family Events.
        </div>
        <table style="width:100%;border-collapse:collapse;background:${THEME.bg};border:1px solid ${THEME.border};border-radius:12px;overflow:hidden;">
          <tr>
            <td style="padding:12px 16px;font-family:${FONT_MONO};font-size:11px;text-transform:uppercase;letter-spacing:0.05em;color:${THEME.textMuted};border-bottom:1px solid ${THEME.border};">Email</td>
            <td style="padding:12px 16px;font-family:${FONT_SANS};font-size:15px;font-weight:600;color:${THEME.textPrimary};border-bottom:1px solid ${THEME.border};">${escapeHtml(payload.email)}</td>
          </tr>
          ${message ? `
          <tr>
            <td style="padding:12px 16px;font-family:${FONT_MONO};font-size:11px;text-transform:uppercase;letter-spacing:0.05em;color:${THEME.textMuted};vertical-align:top;">Message</td>
            <td style="padding:12px 16px;font-family:${FONT_SANS};font-size:14px;color:${THEME.textPrimary};white-space:pre-wrap;">${escapeHtml(message)}</td>
          </tr>` : ""}
        </table>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:28px 40px 36px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td style="background:${THEME.peach};border-radius:9999px;">
              <a href="${escapeHtml(linkUrl)}" style="display:inline-block;font-family:${FONT_SANS};font-size:15px;font-weight:700;color:#FFFFFF;padding:14px 28px;border-radius:9999px;text-decoration:none;">Review in admin &rarr;</a>
            </td>
          </tr>
        </table>
      </td>
    </tr>`

  return {
    to: adminEmail,
    subject: `[Family Events] New invite request from ${payload.email}`,
    html: wrapEmailShell({
      heading: "New Invite Request",
      tagline: "Action needed",
      bodyHtml,
      footerHtml: `<div style="font-family:${FONT_SANS};font-size:12px;line-height:1.6;color:${THEME.textMuted};text-align:center;margin:0;">One-click approve there to generate + reveal the code.</div>`,
      appUrl,
    }),
  }
}

function renderRequestApproved(
  payload: Extract<Payload, { kind: "request_approved" }>,
  appUrl: string
): RenderedEmail {
  const url = (payload.app_url ?? appUrl).replace(/\/$/, "")
  const signupUrl = `${url}/sign-up`

  const bodyHtml = `
    <tr>
      <td style="padding:30px 40px 6px;">
        <div style="font-family:${FONT_EDITORIAL};font-size:17px;line-height:1.55;color:${THEME.textMuted};margin:0 0 20px;">
          Thanks for asking to join Family Events. Here's your invite code:
        </div>
        <div style="background:${THEME.bg};border:1px solid ${THEME.border};border-radius:16px;padding:24px;text-align:center;">
          <div style="font-family:${FONT_MONO};font-size:28px;font-weight:700;letter-spacing:0.2em;color:${THEME.textPrimary};">${escapeHtml(payload.code)}</div>
        </div>
        <div style="font-family:${FONT_SANS};font-size:13px;color:${THEME.textMuted};margin-top:16px;">
          The code is single-use. Paste it on the sign-up screen along with your email to finish creating your account.
        </div>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:28px 40px 36px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td style="background:${THEME.peach};border-radius:9999px;">
              <a href="${escapeHtml(signupUrl)}" style="display:inline-block;font-family:${FONT_SANS};font-size:16px;font-weight:700;color:#FFFFFF;padding:16px 32px;border-radius:9999px;text-decoration:none;">Create your account &rarr;</a>
            </td>
          </tr>
        </table>
      </td>
    </tr>`

  return {
    to: payload.email,
    subject: "Your Family Events invite code",
    html: wrapEmailShell({
      heading: "You're In!",
      tagline: "Welcome aboard",
      bodyHtml,
      footerHtml: `<div style="font-family:${FONT_SANS};font-size:12px;line-height:1.6;color:${THEME.textMuted};text-align:center;margin:0;">Didn't request this? You can safely ignore this email.</div>`,
      appUrl: url,
    }),
  }
}

function renderRequestRejected(
  payload: Extract<Payload, { kind: "request_rejected" }>,
  appUrl: string
): RenderedEmail {
  const bodyHtml = `
    <tr>
      <td style="padding:30px 40px 36px;">
        <div style="font-family:${FONT_EDITORIAL};font-size:17px;line-height:1.55;color:${THEME.textMuted};margin:0 0 16px;">
          Thanks for asking to join Family Events. After review, we're not able to approve your request at this time.
        </div>
        <div style="font-family:${FONT_SANS};font-size:14px;color:${THEME.textMuted};">
          No further action is needed on your end. If you think this was a mistake, please email
          <a href="mailto:support@family-events.org" style="color:${THEME.violetDeep};font-weight:500;text-decoration:underline;">support@family-events.org</a>.
        </div>
      </td>
    </tr>`

  return {
    to: payload.email,
    subject: "Update on your Family Events invite request",
    html: wrapEmailShell({
      heading: "Request Update",
      tagline: "About your invite",
      bodyHtml,
      footerHtml: `<div style="font-family:${FONT_SANS};font-size:12px;line-height:1.6;color:${THEME.textMuted};text-align:center;margin:0;">Didn't request this? You can safely ignore this email.</div>`,
      appUrl,
    }),
  }
}

async function sendViaResend(args: {
  apiKey: string
  from: string
  replyTo?: string
  email: RenderedEmail
}): Promise<{ ok: true; id: string } | { ok: false; status: number; body: string }> {
  const response = await fetch(RESEND_API_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${args.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: args.from,
      to: [args.email.to],
      subject: args.email.subject,
      html: args.email.html,
      ...(args.replyTo ? { reply_to: args.replyTo } : {}),
    }),
    signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
  })

  if (!response.ok) {
    const body = await response.text().catch(() => "")
    return { ok: false, status: response.status, body: body.slice(0, 500) }
  }

  const data = (await response.json().catch(() => ({}))) as { id?: string }
  return { ok: true, id: data.id ?? "" }
}

async function sendViaResendTemplate(args: {
  apiKey: string
  from: string
  to: string
  templateAlias: string
  variables: Record<string, string>
}): Promise<{ ok: true; id: string } | { ok: false; status: number; body: string }> {
  const response = await fetch(RESEND_API_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${args.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: args.from,
      to: [args.to],
      template: {
        id: args.templateAlias,
        variables: args.variables,
      },
    }),
    signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
  })

  if (!response.ok) {
    const body = await response.text().catch(() => "")
    return { ok: false, status: response.status, body: body.slice(0, 500) }
  }

  const data = (await response.json().catch(() => ({}))) as { id?: string }
  return { ok: true, id: data.id ?? "" }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders })
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  const auth = requireServiceRole(req, serviceRoleKey)
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  let payload: Payload
  try {
    payload = parsePayload(await req.json())
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "invalid JSON body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? ""
  const resendFrom = Deno.env.get("RESEND_FROM") ?? "Family Events <onboarding@resend.dev>"
  const resendReplyTo = Deno.env.get("RESEND_REPLY_TO") ?? ""
  const adminEmail = Deno.env.get("ADMIN_NOTIFY_EMAIL") ?? ""
  const appUrl = Deno.env.get("APP_URL") ?? "https://family-events.up.railway.app"

  try {
    // welcome: send via deployed Resend template
    if (payload.kind === "welcome") {
      if (!resendApiKey) {
        logEdgeEvent("warn", "notify-email: RESEND_API_KEY not configured; would have sent welcome", {
          function: "notify-email",
          kind: payload.kind,
          to: payload.email,
        })
        return new Response(JSON.stringify({ sent: false, dev: true }), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        })
      }

      const result = await sendViaResendTemplate({
        apiKey: resendApiKey,
        from: resendFrom,
        to: payload.email,
        templateAlias: "family-events-welcome",
        variables: {
          USERNAME: payload.username,
          APP_URL: appUrl,
        },
      })

      if (!result.ok) {
        logEdgeEvent("error", "notify-email: Resend rejected welcome email", {
          function: "notify-email",
          kind: payload.kind,
          status: result.status,
          body: result.body,
        })
        await captureEdgeException(
          new Error(`Resend ${result.status}: ${result.body.slice(0, 200)}`),
          { function: "notify-email", kind: payload.kind }
        )
        return new Response(JSON.stringify({ sent: false, error: `resend_${result.status}` }), {
          status: 502,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        })
      }

      logEdgeEvent("log", "notify-email: sent", {
        function: "notify-email",
        kind: payload.kind,
        resend_id: result.id,
      })
      return new Response(JSON.stringify({ sent: true, id: result.id }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    // Inline-rendered email kinds
    let rendered: RenderedEmail
    if (payload.kind === "admin_request") {
      if (!adminEmail) {
        logEdgeEvent("warn", "notify-email: ADMIN_NOTIFY_EMAIL not configured; skipping", {
          function: "notify-email",
          kind: payload.kind,
        })
        return new Response(JSON.stringify({ sent: false, reason: "no_admin_email" }), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        })
      }
      rendered = renderAdminRequest(payload, adminEmail, appUrl)
    } else if (payload.kind === "request_approved") {
      rendered = renderRequestApproved(payload, appUrl)
    } else if (payload.kind === "request_rejected") {
      rendered = renderRequestRejected(payload, appUrl)
    } else {
      return new Response(JSON.stringify({ error: "unknown kind" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    // Soft-failure mode: no RESEND_API_KEY → log + 200. Keeps local/dev and
    // misconfigured environments from breaking invite flows.
    if (!resendApiKey) {
      logEdgeEvent("warn", "notify-email: RESEND_API_KEY not configured; would have sent", {
        function: "notify-email",
        kind: payload.kind,
        to: rendered.to,
        subject: rendered.subject,
      })
      return new Response(JSON.stringify({ sent: false, dev: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    const result = await sendViaResend({
      apiKey: resendApiKey,
      from: resendFrom,
      replyTo: resendReplyTo || undefined,
      email: rendered,
    })

    if (!result.ok) {
      logEdgeEvent("error", "notify-email: Resend rejected request", {
        function: "notify-email",
        kind: payload.kind,
        status: result.status,
        body: result.body,
      })
      await captureEdgeException(
        new Error(`Resend ${result.status}: ${result.body.slice(0, 200)}`),
        { function: "notify-email", kind: payload.kind }
      )
      return new Response(JSON.stringify({ sent: false, error: `resend_${result.status}` }), {
        status: 502,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    logEdgeEvent("log", "notify-email: sent", {
      function: "notify-email",
      kind: payload.kind,
      resend_id: result.id,
    })
    return new Response(JSON.stringify({ sent: true, id: result.id }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  } catch (err) {
    await captureEdgeException(err, errorContext(err, { function: "notify-email" }))
    logEdgeEvent(
      "error",
      "notify-email outer failure",
      errorContext(err, { function: "notify-email" })
    )
    return new Response(JSON.stringify({ error: errorMessage(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
})
