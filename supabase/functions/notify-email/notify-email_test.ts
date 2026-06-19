import { assert, assertEquals } from "jsr:@std/assert"
import { escapeHtml } from "../_shared/html.ts"

// ---------------------------------------------------------------------------
// notify-email pins the per-kind Resend contract: which template id (for the
// templated "welcome" kind) and which variable set / subject each payload kind
// produces, plus the no-RESEND_API_KEY soft-fail path.
//
// index.ts calls Deno.serve(...) at module load and does not export its render
// helpers, so (matching the established send-push/send-reminders test style)
// the pure units are mirrored here. Keep these in lockstep with
// supabase/functions/notify-email/index.ts when a template/var changes.
// ---------------------------------------------------------------------------

const RESEND_API_ENDPOINT = "https://api.resend.com/emails"
const RESEND_TIMEOUT_MS = 10_000
const APP_URL = "https://family-events.up.railway.app"

// ── Templated kind: welcome → sendViaResendTemplate ──────────────────────────

interface TemplateCall {
  templateAlias: string
  variables: Record<string, string>
}

function buildWelcomeTemplate(username: string, appUrl: string): TemplateCall {
  return {
    templateAlias: "family-events-welcome",
    variables: {
      USERNAME: username,
      APP_URL: appUrl,
    },
  }
}

Deno.test("welcome maps to family-events-welcome template with USERNAME + APP_URL", () => {
  const call = buildWelcomeTemplate("Alice", APP_URL)
  assertEquals(call.templateAlias, "family-events-welcome")
  assertEquals(call.variables, { USERNAME: "Alice", APP_URL: APP_URL })
})

// ── Inline-rendered kinds: subject + body invariants ─────────────────────────

interface RenderedEmail {
  to: string
  subject: string
  html: string
}

function renderAdminRequest(
  email: string,
  message: string | null,
  adminEmail: string,
  appUrl: string
): RenderedEmail {
  const trimmed = message?.trim()
  const linkUrl = `${appUrl.replace(/\/$/, "")}/admin/invites`
  const messageRow = trimmed ? escapeHtml(trimmed) : ""
  return {
    to: adminEmail,
    subject: `[Family Events] New invite request from ${email}`,
    html: `${escapeHtml(linkUrl)}|${escapeHtml(email)}|${messageRow}`,
  }
}

function renderRequestApproved(email: string, code: string, appUrl: string): RenderedEmail {
  const url = appUrl.replace(/\/$/, "")
  return {
    to: email,
    subject: "Your Family Events invite code",
    html: `${escapeHtml(`${url}/sign-up`)}|${escapeHtml(code)}`,
  }
}

function renderRequestRejected(email: string): RenderedEmail {
  return {
    to: email,
    subject: "Update on your Family Events invite request",
    html: "rejected",
  }
}

function renderCommunityEventStatus(
  email: string,
  username: string,
  eventTitle: string,
  eventId: string | undefined,
  appUrl: string,
  status: "approved" | "rejected"
): RenderedEmail {
  const isApproved = status === "approved"
  const ctaUrl = isApproved && eventId ? `${appUrl}/events/${eventId}` : `${appUrl}/submit-event`
  return {
    to: email,
    subject: isApproved
      ? `Your event "${eventTitle}" is now live!`
      : `Update on your event "${eventTitle}"`,
    html: `${escapeHtml(username)}|${escapeHtml(eventTitle)}|${ctaUrl}`,
  }
}

Deno.test("admin_request: subject names requester; body links admin invites and escapes input", () => {
  const rendered = renderAdminRequest(
    "user@example.com",
    "<script>hi</script> & friends",
    "admin@example.com",
    APP_URL
  )
  assertEquals(rendered.to, "admin@example.com")
  assertEquals(rendered.subject, "[Family Events] New invite request from user@example.com")
  assert(rendered.html.includes(`${APP_URL}/admin/invites`))
  // user-controlled message is HTML-escaped
  assert(rendered.html.includes("&lt;script&gt;hi&lt;/script&gt; &amp; friends"))
  assert(!rendered.html.includes("<script>"))
})

Deno.test("admin_request: empty/whitespace message renders no message row", () => {
  const rendered = renderAdminRequest("user@example.com", "   ", "admin@example.com", APP_URL)
  assertEquals(rendered.html.endsWith("|"), true)
})

Deno.test("request_approved: subject + code, signup link uses payload app_url override", () => {
  const rendered = renderRequestApproved("user@example.com", "ABC123", "https://staging.app/")
  assertEquals(rendered.to, "user@example.com")
  assertEquals(rendered.subject, "Your Family Events invite code")
  // trailing slash stripped, /sign-up appended
  assert(rendered.html.includes("https://staging.app/sign-up"))
  assert(rendered.html.includes("ABC123"))
})

Deno.test("request_rejected: fixed subject to requester", () => {
  const rendered = renderRequestRejected("user@example.com")
  assertEquals(rendered.to, "user@example.com")
  assertEquals(rendered.subject, "Update on your Family Events invite request")
})

Deno.test("community_event_approved: live subject + event CTA url", () => {
  const rendered = renderCommunityEventStatus(
    "user@example.com",
    "Bob",
    "Park Day",
    "e1",
    APP_URL,
    "approved"
  )
  assertEquals(rendered.subject, `Your event "Park Day" is now live!`)
  assert(rendered.html.includes(`${APP_URL}/events/e1`))
  assert(rendered.html.includes("Bob"))
})

Deno.test("community_event_rejected: update subject + submit-event CTA url", () => {
  const rendered = renderCommunityEventStatus(
    "user@example.com",
    "Bob",
    "Park Day",
    undefined,
    APP_URL,
    "rejected"
  )
  assertEquals(rendered.subject, `Update on your event "Park Day"`)
  assert(rendered.html.includes(`${APP_URL}/submit-event`))
})

Deno.test("community event escapes title and username in body", () => {
  const rendered = renderCommunityEventStatus(
    "user@example.com",
    "<b>Bob</b>",
    `"Park" & <Day>`,
    "e1",
    APP_URL,
    "approved"
  )
  assert(rendered.html.includes("&lt;b&gt;Bob&lt;/b&gt;"))
  assert(rendered.html.includes("&quot;Park&quot; &amp; &lt;Day&gt;"))
  assert(!rendered.html.includes("<b>Bob</b>"))
})

// ---------------------------------------------------------------------------
// Resend POST body shape (network mocked via globalThis.fetch).
// ---------------------------------------------------------------------------

async function withFetch(fakeFetch: typeof fetch, fn: () => Promise<void>) {
  const originalFetch = globalThis.fetch
  globalThis.fetch = fakeFetch
  try {
    await fn()
  } finally {
    globalThis.fetch = originalFetch
  }
}

// Mirror of sendViaResend (HTML email kinds).
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

// Mirror of sendViaResendTemplate (welcome kind).
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
      template: { id: args.templateAlias, variables: args.variables },
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

Deno.test("sendViaResend posts html email body to Resend and returns the id", async () => {
  let captured: { url: string; init: RequestInit } | undefined
  const fakeFetch = ((url: string | URL | Request, init?: RequestInit) => {
    captured = { url: String(url), init: init ?? {} }
    return Promise.resolve(
      new Response(JSON.stringify({ id: "resend-123" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    )
  }) as typeof fetch

  await withFetch(fakeFetch, async () => {
    const result = await sendViaResend({
      apiKey: "key-abc",
      from: "Family Events <onboarding@resend.dev>",
      replyTo: "reply@cypress-ink-labs.org",
      email: {
        to: "user@example.com",
        subject: "Your Family Events invite code",
        html: "<p>code</p>",
      },
    })
    assertEquals(result, { ok: true, id: "resend-123" })
  })

  assert(captured !== undefined)
  const { url, init } = captured
  assertEquals(url, RESEND_API_ENDPOINT)
  assertEquals(init.method, "POST")
  const headers = init.headers as Record<string, string>
  assertEquals(headers.Authorization, "Bearer key-abc")
  const body = JSON.parse(init.body as string) as {
    from: string
    to: string[]
    subject: string
    html: string
    reply_to?: string
  }
  assertEquals(body.to, ["user@example.com"])
  assertEquals(body.subject, "Your Family Events invite code")
  assertEquals(body.html, "<p>code</p>")
  assertEquals(body.reply_to, "reply@cypress-ink-labs.org")
})

Deno.test("sendViaResend omits reply_to when not provided", async () => {
  let bodyJson: Record<string, unknown> = {}
  const fakeFetch = ((_url: string | URL | Request, init?: RequestInit) => {
    bodyJson = JSON.parse((init?.body as string) ?? "{}")
    return Promise.resolve(new Response(JSON.stringify({ id: "x" }), { status: 200 }))
  }) as typeof fetch

  await withFetch(fakeFetch, async () => {
    await sendViaResend({
      apiKey: "k",
      from: "f",
      email: { to: "u@e.com", subject: "s", html: "h" },
    })
  })
  assertEquals("reply_to" in bodyJson, false)
})

Deno.test("sendViaResendTemplate posts template id + variables to Resend", async () => {
  let bodyJson: { template?: TemplateCall & { id: string } } = {}
  const fakeFetch = ((_url: string | URL | Request, init?: RequestInit) => {
    bodyJson = JSON.parse((init?.body as string) ?? "{}")
    return Promise.resolve(new Response(JSON.stringify({ id: "tmpl-9" }), { status: 200 }))
  }) as typeof fetch

  await withFetch(fakeFetch, async () => {
    const result = await sendViaResendTemplate({
      apiKey: "k",
      from: "f",
      to: "user@example.com",
      templateAlias: "family-events-welcome",
      variables: { USERNAME: "Alice", APP_URL },
    })
    assertEquals(result, { ok: true, id: "tmpl-9" })
  })
  assertEquals(bodyJson.template?.id, "family-events-welcome")
  assertEquals(bodyJson.template?.variables, { USERNAME: "Alice", APP_URL })
})

Deno.test("sendViaResend surfaces non-2xx as a failure with status + truncated body", async () => {
  const fakeFetch = (() =>
    Promise.resolve(new Response("x".repeat(1000), { status: 422 }))) as typeof fetch

  await withFetch(fakeFetch, async () => {
    const result = await sendViaResend({
      apiKey: "k",
      from: "f",
      email: { to: "u@e.com", subject: "s", html: "h" },
    })
    assertEquals(result.ok, false)
    if (!result.ok) {
      assertEquals(result.status, 422)
      assertEquals(result.body.length, 500)
    }
  })
})

// ---------------------------------------------------------------------------
// Soft-fail path: no RESEND_API_KEY → never hits the network, returns dev:true.
// ---------------------------------------------------------------------------

interface SoftResult {
  status: number
  body: { sent: boolean; dev?: boolean }
  fetched: boolean
}

function dispatchWithKeyGate(resendApiKey: string, sendFn: () => void): SoftResult {
  // Mirrors the index.ts gate: empty key → log + 200 { sent:false, dev:true },
  // without calling Resend.
  if (!resendApiKey) {
    return { status: 200, body: { sent: false, dev: true }, fetched: false }
  }
  sendFn()
  return { status: 200, body: { sent: true }, fetched: true }
}

Deno.test("soft-fail: missing RESEND_API_KEY returns 200 dev:true and skips fetch", () => {
  let sent = false
  const result = dispatchWithKeyGate("", () => {
    sent = true
  })
  assertEquals(result.status, 200)
  assertEquals(result.body, { sent: false, dev: true })
  assertEquals(result.fetched, false)
  assertEquals(sent, false)
})

Deno.test("with RESEND_API_KEY set, dispatch proceeds", () => {
  let sent = false
  const result = dispatchWithKeyGate("key-present", () => {
    sent = true
  })
  assertEquals(result.fetched, true)
  assertEquals(sent, true)
})
