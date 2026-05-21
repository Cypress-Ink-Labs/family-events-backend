import "@supabase/functions-js/edge-runtime.d.ts"
import { requireServiceRole } from "../_shared/auth.ts"
import { captureEdgeException } from "../_shared/sentry.ts"
import { errorContext, logEdgeEvent } from "../_shared/logger.ts"

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

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
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

  return {
    to: adminEmail,
    subject: `[Family Events] New invite request from ${payload.email}`,
    html: `
      <div style="font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif; color: #0f172a; max-width: 560px;">
        <h2 style="margin-bottom: 8px;">New invite request</h2>
        <p style="color: #475569; margin: 0 0 16px;">
          Someone just asked to join Family Events.
        </p>
        <table style="border-collapse: collapse; margin: 16px 0;">
          <tr>
            <td style="padding: 6px 12px 6px 0; color: #64748b; vertical-align: top;">Email</td>
            <td style="padding: 6px 0; font-weight: 600;">${escapeHtml(payload.email)}</td>
          </tr>
          ${
            message
              ? `<tr>
                  <td style="padding: 6px 12px 6px 0; color: #64748b; vertical-align: top;">Message</td>
                  <td style="padding: 6px 0; white-space: pre-wrap;">${escapeHtml(message)}</td>
                </tr>`
              : ""
          }
        </table>
        <p style="margin: 24px 0;">
          <a href="${escapeHtml(linkUrl)}"
             style="background: #f59e0b; color: #0f172a; padding: 10px 16px; border-radius: 10px; text-decoration: none; font-weight: 700;">
            Review in admin
          </a>
        </p>
        <p style="color: #94a3b8; font-size: 12px; margin-top: 32px;">
          One-click approve there to generate + reveal the code.
        </p>
      </div>
    `.trim(),
  }
}

function renderRequestApproved(
  payload: Extract<Payload, { kind: "request_approved" }>,
  appUrl: string
): RenderedEmail {
  const url = (payload.app_url ?? appUrl).replace(/\/$/, "")
  const signupUrl = `${url}/sign-up`

  return {
    to: payload.email,
    subject: "Your Family Events invite code",
    html: `
      <div style="font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif; color: #0f172a; max-width: 560px;">
        <h2 style="margin-bottom: 8px;">You're in!</h2>
        <p style="margin: 0 0 16px;">Thanks for asking to join Family Events. Here's your invite code:</p>
        <div style="background: #f1f5f9; border: 1px solid #cbd5e1; border-radius: 12px; padding: 16px; text-align: center; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 22px; font-weight: 700; letter-spacing: 0.18em;">
          ${escapeHtml(payload.code)}
        </div>
        <p style="margin: 24px 0;">
          <a href="${escapeHtml(signupUrl)}"
             style="background: #f59e0b; color: #0f172a; padding: 10px 16px; border-radius: 10px; text-decoration: none; font-weight: 700;">
            Create your account
          </a>
        </p>
        <p style="color: #475569; font-size: 13px;">
          The code is single-use. Paste it on the sign-up screen along with your email to finish creating your account.
        </p>
        <p style="color: #94a3b8; font-size: 12px; margin-top: 32px;">
          Didn't request this? You can ignore this email.
        </p>
      </div>
    `.trim(),
  }
}

function renderRequestRejected(
  payload: Extract<Payload, { kind: "request_rejected" }>
): RenderedEmail {
  return {
    to: payload.email,
    subject: "Update on your Family Events invite request",
    html: `
      <div style="font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif; color: #0f172a; max-width: 560px;">
        <h2 style="margin-bottom: 8px;">About your invite request</h2>
        <p style="margin: 0 0 16px;">
          Thanks for asking to join Family Events. After review, we're not able to approve your request at this time.
        </p>
        <p style="color: #475569; font-size: 13px;">
          No further action is needed on your end. If you think this was a mistake, please send an email to <a href="mailto:support@family-events.org">support@family-events.org</a>.
        </p>
        <p style="color: #94a3b8; font-size: 12px; margin-top: 32px;">
          Didn't request this? You can ignore this email.
        </p>
      </div>
    `.trim(),
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
    payload = (await req.json()) as Payload
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), {
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
      rendered = renderRequestRejected(payload)
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
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
})
