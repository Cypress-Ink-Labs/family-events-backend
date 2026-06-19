// Unit tests for events-api param validation and cursor encoding.
// Run: cd supabase/functions && deno test --allow-env events-api/events-api_test.ts

import { assertEquals } from "jsr:@std/assert"
import { decodeCursor, handleEventsApi, parseParams, parseRoute } from "./index.ts"

// ── decodeCursor ─────────────────────────────────────────────────────────────

Deno.test("decodeCursor: valid cursor round-trips", () => {
  const afterStart = "2026-07-01T10:00:00.000Z"
  const afterId = "12345678-1234-1234-a234-123456789012"
  const encoded = btoa(JSON.stringify({ after_start: afterStart, after_id: afterId }))
  const result = decodeCursor(encoded)
  assertEquals(result, { after_start: afterStart, after_id: afterId })
})

Deno.test("decodeCursor: rejects malformed base64", () => {
  assertEquals(decodeCursor("!!!not-base64!!!"), null)
})

Deno.test("decodeCursor: rejects valid base64 but invalid JSON", () => {
  assertEquals(decodeCursor(btoa("not json")), null)
})

Deno.test("decodeCursor: rejects cursor with invalid UUID after_id", () => {
  const encoded = btoa(
    JSON.stringify({ after_start: "2026-07-01T10:00:00Z", after_id: "not-a-uuid" })
  )
  assertEquals(decodeCursor(encoded), null)
})

Deno.test("decodeCursor: rejects cursor with invalid date after_start", () => {
  const encoded = btoa(
    JSON.stringify({ after_start: "not-a-date", after_id: "12345678-1234-1234-a234-123456789012" })
  )
  assertEquals(decodeCursor(encoded), null)
})

// ── parseParams ───────────────────────────────────────────────────────────────

function params(obj: Record<string, string>): URLSearchParams {
  return new URLSearchParams(obj)
}

Deno.test("parseParams: empty params yield defaults", () => {
  const result = parseParams(new URLSearchParams())
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(result.params.limit, 20)
  assertEquals(result.params.cityId, null)
  assertEquals(result.params.isFree, null)
  assertEquals(result.params.tags, null)
  assertEquals(result.params.keyword, null)
  assertEquals(result.params.cursor, null)
})

Deno.test("parseParams: valid city_id accepted", () => {
  const result = parseParams(params({ city_id: "12345678-1234-1234-a234-123456789012" }))
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(result.params.cityId, "12345678-1234-1234-a234-123456789012")
})

Deno.test("parseParams: invalid city_id rejected with 400 field", () => {
  const result = parseParams(params({ city_id: "not-a-uuid" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "city_id")
})

Deno.test("parseParams: valid date_from accepted", () => {
  const result = parseParams(params({ date_from: "2026-07-01T00:00:00Z" }))
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(typeof result.params.dateFrom, "string")
})

Deno.test("parseParams: invalid date_from rejected", () => {
  const result = parseParams(params({ date_from: "not-a-date" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "date_from")
})

Deno.test("parseParams: is_free=true parsed as boolean", () => {
  const result = parseParams(params({ is_free: "true" }))
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(result.params.isFree, true)
})

Deno.test("parseParams: is_free=false parsed as boolean", () => {
  const result = parseParams(params({ is_free: "false" }))
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(result.params.isFree, false)
})

Deno.test("parseParams: is_free=maybe rejected", () => {
  const result = parseParams(params({ is_free: "maybe" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "is_free")
})

Deno.test("parseParams: valid tags parsed and split", () => {
  const result = parseParams(params({ tags: "family,outdoor,free" }))
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(result.params.tags, ["family", "outdoor", "free"])
})

Deno.test("parseParams: tag with invalid characters rejected", () => {
  const result = parseParams(params({ tags: "family,INVALID_TAG" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "tags")
})

Deno.test("parseParams: more than 10 tags rejected", () => {
  const result = parseParams(params({ tags: "a,b,c,d,e,f,g,h,i,j,k" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "tags")
})

Deno.test("parseParams: keyword max 100 chars accepted", () => {
  const result = parseParams(params({ keyword: "x".repeat(100) }))
  assertEquals(result.ok, true)
})

Deno.test("parseParams: keyword > 100 chars rejected", () => {
  const result = parseParams(params({ keyword: "x".repeat(101) }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "keyword")
})

Deno.test("parseParams: limit=50 accepted", () => {
  const result = parseParams(params({ limit: "50" }))
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(result.params.limit, 50)
})

Deno.test("parseParams: limit=0 rejected", () => {
  const result = parseParams(params({ limit: "0" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "limit")
})

Deno.test("parseParams: limit=101 rejected (above cap)", () => {
  const result = parseParams(params({ limit: "101" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "limit")
})

Deno.test("parseParams: limit=abc rejected", () => {
  const result = parseParams(params({ limit: "abc" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "limit")
})

Deno.test("parseParams: valid cursor accepted", () => {
  const encoded = btoa(
    JSON.stringify({
      after_start: "2026-07-01T10:00:00.000Z",
      after_id: "12345678-1234-1234-a234-123456789012",
    })
  )
  const result = parseParams(params({ cursor: encoded }))
  assertEquals(result.ok, true)
  if (!result.ok) return
  assertEquals(result.params.cursor?.after_id, "12345678-1234-1234-a234-123456789012")
})

Deno.test("parseParams: invalid cursor rejected", () => {
  const result = parseParams(params({ cursor: "not-valid-base64!!!" }))
  assertEquals(result.ok, false)
  if (result.ok) return
  assertEquals(result.error.field, "cursor")
})

// ── parseRoute (GET /events vs GET /events/{id}) ───────────────────────────────

const VALID_ID = "12345678-1234-1234-a234-123456789012"

Deno.test("parseRoute: function root is the list collection", () => {
  assertEquals(parseRoute("/functions/v1/events-api"), { kind: "list" })
  assertEquals(parseRoute("/functions/v1/events-api/"), { kind: "list" })
})

Deno.test("parseRoute: trailing UUID segment is a single-event lookup", () => {
  assertEquals(parseRoute(`/functions/v1/events-api/${VALID_ID}`), {
    kind: "event",
    id: VALID_ID,
  })
})

Deno.test("parseRoute: URL-encoded UUID is decoded", () => {
  assertEquals(parseRoute(`/functions/v1/events-api/${encodeURIComponent(VALID_ID)}`), {
    kind: "event",
    id: VALID_ID,
  })
})

Deno.test("parseRoute: non-UUID single segment is unknown (reserved for future routes)", () => {
  assertEquals(parseRoute("/functions/v1/events-api/cities"), { kind: "unknown" })
  assertEquals(parseRoute("/functions/v1/events-api/not-a-uuid"), { kind: "unknown" })
})

Deno.test("parseRoute: multi-segment tail (e.g. {id}/similar) is unknown — not built", () => {
  assertEquals(parseRoute(`/functions/v1/events-api/${VALID_ID}/similar`), { kind: "unknown" })
})

Deno.test("parseRoute: malformed percent-encoding is unknown (must not throw → no 500)", () => {
  // decodeURIComponent("%E0%A4%A") throws URIError; parseRoute must catch it.
  assertEquals(parseRoute("/functions/v1/events-api/%E0%A4%A"), { kind: "unknown" })
})

// ── handleEventsApi routing guards (resolved before any DB call) ───────────────

Deno.test("handleEventsApi: OPTIONS preflight returns 200", async () => {
  const res = await handleEventsApi(
    new Request("https://x/functions/v1/events-api", { method: "OPTIONS" })
  )
  assertEquals(res.status, 200)
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*")
})

Deno.test("handleEventsApi: non-GET method → 405", async () => {
  const res = await handleEventsApi(
    new Request("https://x/functions/v1/events-api", { method: "POST" })
  )
  assertEquals(res.status, 405)
  assertEquals((await res.json()).error, "method not allowed")
})

Deno.test("handleEventsApi: unknown route → 404", async () => {
  const res = await handleEventsApi(
    new Request("https://x/functions/v1/events-api/cities", { method: "GET" })
  )
  assertEquals(res.status, 404)
  assertEquals((await res.json()).error, "not found")
})

Deno.test("handleEventsApi: {id}/similar is not built → 404", async () => {
  const res = await handleEventsApi(
    new Request(`https://x/functions/v1/events-api/${VALID_ID}/similar`, { method: "GET" })
  )
  assertEquals(res.status, 404)
})

Deno.test("handleEventsApi: missing env → 503 before any DB call", async () => {
  // Ensure the env is unset so getAnonClient() returns null and we never touch
  // the network. The single-event route reaches this guard with a valid id.
  const prevUrl = Deno.env.get("SUPABASE_URL")
  const prevKey = Deno.env.get("SUPABASE_ANON_KEY")
  Deno.env.delete("SUPABASE_URL")
  Deno.env.delete("SUPABASE_ANON_KEY")
  try {
    const res = await handleEventsApi(
      new Request(`https://x/functions/v1/events-api/${VALID_ID}`, { method: "GET" })
    )
    assertEquals(res.status, 503)
    assertEquals((await res.json()).error, "service unavailable")
  } finally {
    if (prevUrl !== undefined) Deno.env.set("SUPABASE_URL", prevUrl)
    if (prevKey !== undefined) Deno.env.set("SUPABASE_ANON_KEY", prevKey)
  }
})
