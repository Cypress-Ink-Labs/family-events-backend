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

function buildActionEmailHtml({
  username,
  intro,
  actionLabel,
  actionUrl,
}: {
  username: string;
  intro: string;
  actionLabel: string;
  actionUrl: string;
}): string {
  return `
    <div style="font-family: ui-sans-serif, system-ui, sans-serif; color: #0f172a; max-width: 560px;">
      <h2 style="margin-bottom: 8px;">${escapeHtml(actionLabel)}</h2>
      <p style="margin: 0 0 16px;">Hi ${escapeHtml(username)},</p>
      <p style="margin: 0 0 24px;">${escapeHtml(intro)}</p>
      <p style="margin: 0 0 24px;">
        <a href="${escapeHtml(actionUrl)}"
           style="background: #4f46e5; color: #fff; padding: 10px 20px; border-radius: 6px; text-decoration: none; font-weight: 700;">
          ${escapeHtml(actionLabel)}
        </a>
      </p>
      <p style="color: #94a3b8; font-size: 12px; margin-top: 32px;">
        If you didn't request this, you can safely ignore this email.
      </p>
    </div>
  `.trim();
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
      const actionLabel = email_action_type === "signup"
        ? "Confirm your email"
        : "Sign in to Family Events";
      body = {
        from: resendFrom,
        to: [user.email],
        subject: email_action_type === "signup"
          ? "Confirm your Family Events email"
          : "Your Family Events sign-in link",
        html: buildActionEmailHtml({
          username,
          intro:
            "Click the button below to continue to Family Events. This link expires in 24 hours.",
          actionLabel,
          actionUrl: verifyLink,
        }),
      };
    } else if (email_action_type === "recovery") {
      body = {
        from: resendFrom,
        to: [user.email],
        subject: "Reset your Family Events password",
        html: buildActionEmailHtml({
          username,
          intro:
            "Click the button below to reset your Family Events password. This link expires in 24 hours.",
          actionLabel: "Reset password",
          actionUrl: verifyLink,
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
          intro: "Click the button below to confirm.",
          actionLabel: "Confirm",
          actionUrl: verifyLink,
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
