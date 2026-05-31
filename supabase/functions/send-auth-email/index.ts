import "@supabase/functions-js/edge-runtime.d.ts";
import { Webhook } from "npm:standardwebhooks@1.0.0";
import { escapeHtml } from "../_shared/html.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, logEdgeEvent } from "../_shared/logger.ts";

// send-auth-email
// ----------------------------------------------------------------
// Supabase Auth send_email hook. Replaces Supabase's built-in email
// sending for all auth flows (magic link, signup confirmation,
// password recovery, email change).
//
// Magic link and signup confirmation → family-events-magic-link
// Resend template (deployed via packages/email/scripts/deploy-templates.tsx).
// All other types → inline HTML.
//
// Soft-failure mode: when RESEND_API_KEY is unset (local/dev) the
// function logs the would-be email and returns {} so Supabase Auth
// does not block the flow. Auth emails are fire-and-forget from
// Supabase's perspective once the hook returns 200.
//
// Production setup: configure [auth.hook.send_email] in the Supabase
// dashboard with this function's URL and an HMAC secret for signature
// verification.

const RESEND_API_ENDPOINT = "https://api.resend.com/emails";
const RESEND_TIMEOUT_MS = 10_000;
const JSON_HEADERS = { "Content-Type": "application/json" };

interface AuthEmailHookPayload {
  user: {
    id: string;
    email: string;
    user_metadata?: {
      display_name?: string;
      name?: string;
      full_name?: string;
    };
  };
  email_data: {
    token: string;
    token_hash: string;
    redirect_to: string;
    email_action_type:
      | "signup"
      | "magiclink"
      | "recovery"
      | "email_change_new"
      | "email_change_current"
      | "reauthentication";
    site_url: string;
    token_new?: string;
    token_hash_new?: string;
  };
}

function usernameFromUser(user: AuthEmailHookPayload["user"]): string {
  return (
    user.user_metadata?.display_name ??
      user.user_metadata?.name ??
      user.user_metadata?.full_name ??
      user.email.split("@")[0]
  );
}

function buildVerifyLink(
  emailData: AuthEmailHookPayload["email_data"],
): string {
  const authBaseUrl = (Deno.env.get("SUPABASE_URL") ?? emailData.site_url)
    .replace(/\/auth\/v1\/?$/, "")
    .replace(/\/$/, "");
  const params = new URLSearchParams({
    token: emailData.token_hash,
    type: emailData.email_action_type,
    redirect_to: emailData.redirect_to,
  });
  return `${authBaseUrl}/auth/v1/verify?${params.toString()}`;
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
} as const;

const FONT_SANS = `'DM Sans', ui-sans-serif, system-ui, -apple-system, sans-serif`;
const FONT_DISPLAY = `'Fraunces', ui-serif, Georgia, serif`;
const FONT_EDITORIAL = `'Newsreader', ui-serif, Georgia, serif`;
const FONT_MONO = `'Geist Mono', ui-monospace, 'SF Mono', monospace`;

function buildActionEmailHtml({
  username,
  intro,
  actionLabel,
  actionUrl,
  heading,
  tagline,
}: {
  username: string;
  intro: string;
  actionLabel: string;
  actionUrl: string;
  heading?: string;
  tagline?: string;
}): string {
  const logoUrl = (Deno.env.get("APP_URL") ?? "https://family-events.up.railway.app").replace(/\/$/, "") + "/brand/family-events-logo.png";
  const displayHeading = heading ?? actionLabel;
  const displayTagline = tagline ?? "One-click access";

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
              <div style="font-family:${FONT_DISPLAY};font-size:34px;line-height:1.1;font-weight:600;color:#FFFFFF;margin:22px 0 0;">${escapeHtml(displayHeading)}</div>
              <div style="display:inline-block;margin-top:14px;background:rgba(255,255,255,0.16);border:1px solid rgba(255,255,255,0.25);border-radius:9999px;padding:6px 14px;font-family:${FONT_MONO};font-size:12px;letter-spacing:0.03em;color:#FFFFFF;">${escapeHtml(displayTagline)}</div>
            </td>
          </tr>
          <!-- Body -->
          <tr>
            <td style="padding:30px 40px 6px;">
              <div style="font-family:${FONT_DISPLAY};font-size:21px;font-weight:600;color:${THEME.textPrimary};margin:0 0 8px;">Hi ${escapeHtml(username)},</div>
              <div style="font-family:${FONT_EDITORIAL};font-size:17px;line-height:1.55;color:${THEME.textMuted};margin:0;">${escapeHtml(intro)}</div>
            </td>
          </tr>
          <!-- CTA -->
          <tr>
            <td align="center" style="padding:28px 40px 36px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td style="background:${THEME.peach};border-radius:9999px;">
                    <a href="${escapeHtml(actionUrl)}" style="display:inline-block;font-family:${FONT_SANS};font-size:16px;font-weight:700;color:#FFFFFF;padding:16px 32px;border-radius:9999px;text-decoration:none;">${escapeHtml(actionLabel)}</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <!-- Footer -->
          <tr>
            <td style="background:${THEME.bg};padding:26px 40px;border-top:1px solid ${THEME.border};">
              <div style="font-family:${FONT_SANS};font-size:12px;line-height:1.6;color:${THEME.textMuted};text-align:center;margin:0;">
                If you didn't request this, you can safely ignore this email.
              </div>
              <div style="font-family:${FONT_MONO};font-size:11px;letter-spacing:0.04em;color:${THEME.textMuted};text-align:center;margin:14px 0 0;opacity:0.7;">FAMILY EVENTS</div>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`.trim();
}

type ResendBody = { from: string; to: string[]; subject: string; html: string };

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS,
  });
}

async function sendEmail(
  apiKey: string,
  body: ResendBody,
): Promise<
  { ok: true; id: string } | { ok: false; status: number; body: string }
> {
  const response = await fetch(RESEND_API_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    return { ok: false, status: response.status, body: text.slice(0, 500) };
  }

  const data = (await response.json().catch(() => ({}))) as { id?: string };
  return { ok: true, id: data.id ?? "" };
}

Deno.serve(async (req: Request) => {
  // Standard Webhooks signature verification. Supabase Auth signs the send_email
  // hook payload with the secret configured in [auth.hook.send_email]
  // (format: "v1,whsec_<base64>"). Without this check the endpoint is a public,
  // unauthenticated email sender (auth bypass / phishing / Resend abuse).
  const hookSecret = Deno.env.get("SEND_EMAIL_HOOK_SECRET") ?? "";
  const raw = await req.text();

  if (hookSecret) {
    try {
      // standardwebhooks expects the bare base64 secret, not the "v1,whsec_" prefix.
      const wh = new Webhook(hookSecret.replace(/^v1,whsec_/, ""));
      wh.verify(raw, {
        "webhook-id": req.headers.get("webhook-id") ?? "",
        "webhook-timestamp": req.headers.get("webhook-timestamp") ?? "",
        "webhook-signature": req.headers.get("webhook-signature") ?? "",
      });
    } catch (_err) {
      logEdgeEvent("warn", "send-auth-email: invalid webhook signature", {
        function: "send-auth-email",
      });
      return jsonResponse({ error: "invalid signature" }, 401);
    }
  } else {
    // Local/dev only: no secret configured. Supabase CLI / Inbucket flows run
    // without a hook secret. Production MUST set SEND_EMAIL_HOOK_SECRET.
    logEdgeEvent(
      "warn",
      "send-auth-email: SEND_EMAIL_HOOK_SECRET not set; skipping signature verification (dev only)",
      { function: "send-auth-email" },
    );
  }

  let payload: AuthEmailHookPayload;
  try {
    payload = JSON.parse(raw) as AuthEmailHookPayload;
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, 400);
  }

  const { user, email_data } = payload;
  const { email_action_type } = email_data;

  const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const resendFrom = Deno.env.get("RESEND_FROM") ??
    "Family Events <onboarding@resend.dev>";
  const username = usernameFromUser(user);

  if (!resendApiKey) {
    logEdgeEvent("warn", "send-auth-email: RESEND_API_KEY not set; skipping", {
      function: "send-auth-email",
      email_action_type,
    });
    // Return success so Supabase Auth does not block the flow in local/dev
    return jsonResponse({});
  }

  try {
    const verifyLink = buildVerifyLink(email_data);
    let body: ResendBody;

    if (email_action_type === "magiclink" || email_action_type === "signup") {
      const isSignup = email_action_type === "signup";
      body = {
        from: resendFrom,
        to: [user.email],
        subject: isSignup
          ? "Confirm your Family Events email"
          : "Your Family Events sign-in link",
        html: buildActionEmailHtml({
          username,
          intro: "Click the button below to continue to Family Events. This link expires in 24 hours.",
          actionLabel: isSignup ? "Confirm email" : "Sign in to Family Events",
          actionUrl: verifyLink,
          heading: isSignup ? "Confirm Your Email" : "Sign In",
          tagline: isSignup ? "One step left" : "One-click access",
        }),
      };
    } else if (email_action_type === "recovery") {
      body = {
        from: resendFrom,
        to: [user.email],
        subject: "Reset your Family Events password",
        html: buildActionEmailHtml({
          username,
          intro: "Click the button below to reset your Family Events password. This link expires in 24 hours.",
          actionLabel: "Reset password",
          actionUrl: verifyLink,
          heading: "Reset Password",
          tagline: "Secure access",
        }),
      };
    } else {
      // email_change_new, email_change_current, reauthentication
      body = {
        from: resendFrom,
        to: [user.email],
        subject: "Confirm your action on Family Events",
        html: buildActionEmailHtml({
          username,
          intro: "Click the button below to confirm your action.",
          actionLabel: "Confirm",
          actionUrl: verifyLink,
          heading: "Confirm Action",
          tagline: "Security verification",
        }),
      };
    }

    const result = await sendEmail(resendApiKey, body);

    if (!result.ok) {
      logEdgeEvent("error", "send-auth-email: Resend rejected request", {
        function: "send-auth-email",
        email_action_type,
        status: result.status,
        body: result.body,
      });
      await captureEdgeException(
        new Error(`Resend ${result.status}: ${result.body}`),
        { function: "send-auth-email", email_action_type },
      );
      // Non-200 tells Supabase Auth the email failed (it will surface an error
      // to the user). This is intentional — a failed delivery is better than
      // silently dropping authentication emails.
      return jsonResponse({ error: `resend_${result.status}` }, 502);
    }

    logEdgeEvent("log", "send-auth-email: sent", {
      function: "send-auth-email",
      email_action_type,
      resend_id: result.id,
    });
    return jsonResponse({});
  } catch (err) {
    await captureEdgeException(
      err,
      errorContext(err, { function: "send-auth-email" }),
    );
    logEdgeEvent(
      "error",
      "send-auth-email outer failure",
      errorContext(err, { function: "send-auth-email" }),
    );
    // Generic body — full detail is in the Sentry capture + log above.
    return jsonResponse(
      {
        error: "Internal error",
        executionId: Deno.env.get("SB_EXECUTION_ID") ?? null,
      },
      500,
    );
  }
});
