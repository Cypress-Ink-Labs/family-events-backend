import { assertEquals } from "jsr:@std/assert";
import {
  buildCorsHeaders,
  errorJson,
  jsonResponse,
  optionsResponse,
} from "./http.ts";

Deno.test("buildCorsHeaders returns service-role defaults", () => {
  assertEquals(buildCorsHeaders(), {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "Content-Type, Authorization, X-Client-Info, Apikey",
  });
});

Deno.test("buildCorsHeaders supports method overrides", () => {
  assertEquals(
    buildCorsHeaders({ methods: ["GET", "OPTIONS"] })[
      "Access-Control-Allow-Methods"
    ],
    "GET, OPTIONS",
  );
});

Deno.test("jsonResponse writes json content type and body", async () => {
  const response = jsonResponse({ ok: true });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("Content-Type"), "application/json");
  assertEquals(await response.json(), { ok: true });
});

Deno.test("errorJson writes standard error body", async () => {
  const response = errorJson("bad", 400);
  assertEquals(response.status, 400);
  assertEquals(await response.json(), { error: "bad" });
});

Deno.test("optionsResponse returns empty 200", async () => {
  const response = optionsResponse(buildCorsHeaders());
  assertEquals(response.status, 200);
  assertEquals(await response.text(), "");
});
