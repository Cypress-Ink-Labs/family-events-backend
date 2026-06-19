import { assertEquals } from "jsr:@std/assert"
import {
  buildCorsHeaders,
  buildPublicCorsHeaders,
  DEFAULT_ALLOWED_ORIGINS,
  resolveAllowedOrigin,
} from "./cors.ts"

// ---------------------------------------------------------------------------
// resolveAllowedOrigin
// ---------------------------------------------------------------------------

Deno.test("resolveAllowedOrigin returns origin for allowlisted value", () => {
  assertEquals(resolveAllowedOrigin("https://family-events.org"), "https://family-events.org")
})

Deno.test("resolveAllowedOrigin returns null for a random origin", () => {
  assertEquals(resolveAllowedOrigin("https://evil.example.com"), null)
})

Deno.test("resolveAllowedOrigin returns null for null origin", () => {
  assertEquals(resolveAllowedOrigin(null), null)
})

Deno.test("resolveAllowedOrigin honors ALLOWED_ORIGINS env override", () => {
  const original = Deno.env.get("ALLOWED_ORIGINS")
  try {
    Deno.env.set("ALLOWED_ORIGINS", "https://custom.example.com")
    assertEquals(resolveAllowedOrigin("https://custom.example.com"), "https://custom.example.com")
    // A default-list origin should not be allowed when override is set
    assertEquals(resolveAllowedOrigin(DEFAULT_ALLOWED_ORIGINS[0]), null)
  } finally {
    if (original === undefined) {
      Deno.env.delete("ALLOWED_ORIGINS")
    } else {
      Deno.env.set("ALLOWED_ORIGINS", original)
    }
  }
})

// ---------------------------------------------------------------------------
// buildCorsHeaders
// ---------------------------------------------------------------------------

Deno.test("buildCorsHeaders(null) omits ACAO but sets Vary: Origin", () => {
  const headers = buildCorsHeaders(null)
  assertEquals(headers["Access-Control-Allow-Origin"], undefined)
  assertEquals(headers["Vary"], "Origin")
})

Deno.test("buildCorsHeaders with allowlisted origin sets ACAO to that origin", () => {
  const headers = buildCorsHeaders("https://family-events.org")
  assertEquals(headers["Access-Control-Allow-Origin"], "https://family-events.org")
  assertEquals(headers["Vary"], "Origin")
})

Deno.test("buildCorsHeaders sets default methods when none provided", () => {
  const headers = buildCorsHeaders("https://family-events.org")
  assertEquals(headers["Access-Control-Allow-Methods"], "POST, OPTIONS")
})

Deno.test("buildCorsHeaders respects custom methods", () => {
  const headers = buildCorsHeaders("https://family-events.org", ["GET", "OPTIONS"])
  assertEquals(headers["Access-Control-Allow-Methods"], "GET, OPTIONS")
})

// ---------------------------------------------------------------------------
// buildPublicCorsHeaders
// ---------------------------------------------------------------------------

Deno.test("buildPublicCorsHeaders serves every origin with * and omits Vary", () => {
  const headers = buildPublicCorsHeaders()
  assertEquals(headers["Access-Control-Allow-Origin"], "*")
  assertEquals(headers["Vary"], undefined)
})

Deno.test("buildPublicCorsHeaders defaults to GET, OPTIONS and the full allow-headers", () => {
  const headers = buildPublicCorsHeaders()
  assertEquals(headers["Access-Control-Allow-Methods"], "GET, OPTIONS")
  assertEquals(
    headers["Access-Control-Allow-Headers"],
    "Content-Type, Authorization, X-Client-Info, Apikey"
  )
})

Deno.test("buildPublicCorsHeaders respects custom methods and allow-headers", () => {
  const headers = buildPublicCorsHeaders(["POST", "OPTIONS"], ["Content-Type", "Apikey"])
  assertEquals(headers["Access-Control-Allow-Methods"], "POST, OPTIONS")
  assertEquals(headers["Access-Control-Allow-Headers"], "Content-Type, Apikey")
})
