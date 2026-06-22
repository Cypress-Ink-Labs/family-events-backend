// Resend email API helper — wraps guardedFetch for SSRF safety.

import { guardedFetch, type GuardedFetchOptions } from "./guarded-fetch.ts"
import { RESEND_API_ENDPOINT, RESEND_TIMEOUT_MS } from "./resend-config.ts"

export interface SendResendEmailOpts extends GuardedFetchOptions {
  // inherits `resolve` from GuardedFetchOptions for unit-test injection
}

export interface ResendResult {
  ok: boolean
  status: number
  /** Raw response body text on failure (truncated to 300 chars). */
  errorBody?: string
}

/**
 * POST an email payload to the Resend API.
 *
 * Uses guardedFetch (SSRF-safe) to POST to {@link RESEND_API_ENDPOINT}.
 *
 * - Returns `{ ok: true, status }` on HTTP 2xx.
 * - Returns `{ ok: false, status, errorBody }` on non-2xx — never throws.
 * - Forward `opts.resolve` to inject a no-op SSRF resolver in unit tests.
 */
export async function sendResendEmail(
  apiKey: string,
  payload: unknown,
  opts: SendResendEmailOpts = {}
): Promise<ResendResult> {
  const response = await guardedFetch(
    RESEND_API_ENDPOINT,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(RESEND_TIMEOUT_MS),
    },
    { resolve: opts.resolve, maxRedirects: opts.maxRedirects }
  )

  if (response.ok) {
    return { ok: true, status: response.status }
  }

  const errorBody = await response.text().catch(() => "")
  return { ok: false, status: response.status, errorBody: errorBody.slice(0, 300) }
}
