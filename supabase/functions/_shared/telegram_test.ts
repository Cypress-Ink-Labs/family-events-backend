import { assertEquals } from "jsr:@std/assert"
import { sendTelegramMessage, TELEGRAM_API_BASE } from "./telegram.ts"
import type { PublicIpResolver } from "./guarded-fetch.ts"

// No-op SSRF resolver — bypasses real DNS lookups in unit tests.
const noopResolve: PublicIpResolver = (_url) => Promise.resolve({ ok: true })

// Capture the last fetch call so tests can assert on URL + body.
interface CapturedRequest {
  url: string
  init: RequestInit
}

function makeMockFetch(
  status: number,
  responseBody: unknown
): { fetch: typeof globalThis.fetch; captured: CapturedRequest[] } {
  const captured: CapturedRequest[] = []
  const mockFetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    captured.push({ url, init: init ?? {} })
    return Promise.resolve(
      new Response(JSON.stringify(responseBody), {
        status,
        headers: { "Content-Type": "application/json" },
      })
    )
  }
  return { fetch: mockFetch as typeof globalThis.fetch, captured }
}

// ---------------------------------------------------------------------------

Deno.test("sendTelegramMessage: 2xx response returns { ok: true }", async () => {
  const { fetch: mockFetch, captured } = makeMockFetch(200, { ok: true, result: { message_id: 1 } })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendTelegramMessage("BOT_TOKEN", "123456", "Hello!", {
      resolve: noopResolve,
    })

    assertEquals(result, { ok: true })
    assertEquals(captured.length, 1)
    assertEquals(captured[0].url, `${TELEGRAM_API_BASE}/botBOT_TOKEN/sendMessage`)

    const body = JSON.parse(captured[0].init.body as string)
    assertEquals(body.chat_id, "123456")
    assertEquals(body.text, "Hello!")
    assertEquals(body.parse_mode, "HTML")
    assertEquals(body.disable_web_page_preview, true)
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendTelegramMessage: Telegram { ok: false, description } returns { ok: false, error }", async () => {
  const { fetch: mockFetch } = makeMockFetch(400, {
    ok: false,
    error_code: 400,
    description: "Bad Request: chat not found",
  })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendTelegramMessage("BOT_TOKEN", "bad_chat", "Hello!", {
      resolve: noopResolve,
    })

    assertEquals(result.ok, false)
    assertEquals(result.error, "Bad Request: chat not found")
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendTelegramMessage: non-2xx without description returns HTTP status in error", async () => {
  const { fetch: mockFetch } = makeMockFetch(500, { something: "unexpected" })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendTelegramMessage("BOT_TOKEN", "123456", "Hello!", {
      resolve: noopResolve,
    })

    assertEquals(result.ok, false)
    assertEquals(result.error, "HTTP 500")
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendTelegramMessage: network error returns { ok: false, error } without throwing", async () => {
  const original = globalThis.fetch
  globalThis.fetch = (_input: unknown, _init?: unknown): Promise<Response> => {
    return Promise.reject(new Error("network failure"))
  }

  try {
    const result = await sendTelegramMessage("BOT_TOKEN", "123456", "Hello!", {
      resolve: noopResolve,
    })

    assertEquals(result.ok, false)
    assertEquals(result.error, "network failure")
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendTelegramMessage: URL contains bot token and correct path", async () => {
  const { fetch: mockFetch, captured } = makeMockFetch(200, { ok: true })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    await sendTelegramMessage("MY_SECRET_TOKEN", "789", "test", {
      resolve: noopResolve,
    })

    assertEquals(captured[0].url, `${TELEGRAM_API_BASE}/botMY_SECRET_TOKEN/sendMessage`)
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendTelegramMessage: HTTP 200 with ok:false is a failure (not misreported)", async () => {
  // Telegram returns 200 OK with ok:false for many errors (blocked bot, etc.).
  const { fetch: mockFetch } = makeMockFetch(200, {
    ok: false,
    error_code: 403,
    description: "Forbidden: bot was blocked by the user",
  })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendTelegramMessage("BOT_TOKEN", "123456", "Hello!", {
      resolve: noopResolve,
    })

    assertEquals(result.ok, false)
    assertEquals(result.error, "Forbidden: bot was blocked by the user")
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendTelegramMessage: bot token is redacted from error messages", async () => {
  const original = globalThis.fetch
  globalThis.fetch = (_input: unknown, _init?: unknown): Promise<Response> =>
    Promise.reject(new Error("fetch failed for https://api.telegram.org/botSECRET123/sendMessage"))

  try {
    const result = await sendTelegramMessage("SECRET123", "789", "hi", {
      resolve: noopResolve,
    })

    assertEquals(result.ok, false)
    assertEquals(result.error?.includes("SECRET123"), false)
    assertEquals(result.error?.includes("[REDACTED]"), true)
  } finally {
    globalThis.fetch = original
  }
})
