// Telegram Bot API helper — wraps guardedFetch for SSRF safety.

import { guardedFetch, type GuardedFetchOptions } from "./guarded-fetch.ts"

export const TELEGRAM_API_BASE = "https://api.telegram.org"
export const TELEGRAM_TIMEOUT_MS = 10_000

export interface SendTelegramMessageOpts extends GuardedFetchOptions {
  // inherits `resolve` from GuardedFetchOptions for unit-test injection
}

export interface TelegramResult {
  ok: boolean
  error?: string
}

/**
 * Send a Telegram message via the Bot API.
 *
 * Uses guardedFetch (SSRF-safe) to POST to
 * `https://api.telegram.org/bot<token>/sendMessage`.
 *
 * - Returns `{ ok: true }` on HTTP 2xx + Telegram `ok: true`.
 * - Returns `{ ok: false, error }` on any failure — never throws.
 * - Forward `opts.resolve` to inject a no-op SSRF resolver in unit tests.
 */
export async function sendTelegramMessage(
  botToken: string,
  chatId: string,
  text: string,
  opts: SendTelegramMessageOpts = {}
): Promise<TelegramResult> {
  const url = `${TELEGRAM_API_BASE}/bot${botToken}/sendMessage`
  try {
    const response = await guardedFetch(
      url,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: chatId,
          text,
          parse_mode: "HTML",
          disable_web_page_preview: true,
        }),
        signal: AbortSignal.timeout(TELEGRAM_TIMEOUT_MS),
      },
      { resolve: opts.resolve, maxRedirects: opts.maxRedirects }
    )

    if (response.ok) {
      return { ok: true }
    }

    // Non-2xx: attempt to parse Telegram's error body
    let description: string | undefined
    try {
      const body = (await response.json()) as { ok?: boolean; description?: string }
      if (typeof body.description === "string") {
        description = body.description
      }
    } catch {
      // ignore parse failure
    }

    return {
      ok: false,
      error: description ?? `HTTP ${response.status}`,
    }
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    }
  }
}
