import { assertEquals } from "jsr:@std/assert"
import { errorJson, jsonResponse, optionsResponse } from "./http.ts"

Deno.test("jsonResponse writes json content type and body", async () => {
  const response = jsonResponse({ ok: true })
  assertEquals(response.status, 200)
  assertEquals(response.headers.get("Content-Type"), "application/json")
  assertEquals(await response.json(), { ok: true })
})

Deno.test("errorJson writes standard error body", async () => {
  const response = errorJson("bad", 400)
  assertEquals(response.status, 400)
  assertEquals(await response.json(), { error: "bad" })
})

Deno.test("optionsResponse returns empty 200 and passes through headers", async () => {
  const response = optionsResponse({ "Access-Control-Allow-Methods": "POST, OPTIONS" })
  assertEquals(response.status, 200)
  assertEquals(response.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS")
  assertEquals(await response.text(), "")
})
