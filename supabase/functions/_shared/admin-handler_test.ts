import { assertEquals } from "jsr:@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import { createAdminJsonHandler } from "./admin-handler.ts";

function env(values: Record<string, string | undefined>) {
  return { get: (name: string) => values[name] };
}

function request(method = "POST") {
  return new Request("https://example.com/functions/v1/admin-run-cron", {
    headers: { Authorization: "Bearer token" },
    method,
  });
}

Deno.test("createAdminJsonHandler returns OPTIONS preflight", async () => {
  const handler = createAdminJsonHandler(
    { functionName: "admin-test" },
    async () => ({ ok: true }),
  );
  const response = await handler(request("OPTIONS"));
  assertEquals(response.status, 200);
  assertEquals(
    response.headers.get("Access-Control-Allow-Methods"),
    "POST, OPTIONS",
  );
});

Deno.test("createAdminJsonHandler validates required env", async () => {
  const handler = createAdminJsonHandler(
    { functionName: "admin-test" },
    async () => ({ ok: true }),
    { env: env({}) },
  );
  const response = await handler(request());
  assertEquals(response.status, 500);
  assertEquals(await response.json(), { error: "SUPABASE_URL not configured" });
});

Deno.test("createAdminJsonHandler delegates auth and returns handler JSON", async () => {
  let authCalled = false;
  const handler = createAdminJsonHandler(
    { functionName: "admin-test" },
    async ({ auth }) => ({ source: auth.source }),
    {
      createServiceClient: () => ({}) as SupabaseClient,
      env: env({
        SUPABASE_ANON_KEY: "anon",
        SUPABASE_SERVICE_ROLE_KEY: "service",
        SUPABASE_URL: "https://project.supabase.co",
      }),
      requireAdminOrService: (async () => {
        authCalled = true;
        return { ok: true, source: "service_role", userId: null };
      }) as never,
    },
  );
  const response = await handler(request());
  assertEquals(authCalled, true);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { source: "service_role" });
});

Deno.test("createAdminJsonHandler merges CORS headers into handler Response returns", async () => {
  const handler = createAdminJsonHandler(
    { functionName: "admin-test" },
    async () =>
      new Response(JSON.stringify({ ok: true }), {
        headers: { "Content-Type": "application/json" },
        status: 200,
      }),
    {
      createServiceClient: () => ({}) as SupabaseClient,
      env: env({
        SUPABASE_ANON_KEY: "anon",
        SUPABASE_SERVICE_ROLE_KEY: "service",
        SUPABASE_URL: "https://project.supabase.co",
      }),
      requireAdminOrService: (async () => ({
        ok: true,
        source: "service_role",
        userId: null,
      })) as never,
    },
  );
  const response = await handler(request());
  assertEquals(response.status, 200);
  assertEquals(
    response.headers.get("Access-Control-Allow-Methods"),
    "POST, OPTIONS",
  );
  assertEquals(await response.json(), { ok: true });
});

Deno.test("createAdminJsonHandler returns auth failures", async () => {
  const handler = createAdminJsonHandler(
    { functionName: "admin-test" },
    async () => ({ ok: true }),
    {
      createServiceClient: () => ({}) as SupabaseClient,
      env: env({
        SUPABASE_ANON_KEY: "anon",
        SUPABASE_SERVICE_ROLE_KEY: "service",
        SUPABASE_URL: "https://project.supabase.co",
      }),
      requireAdminOrService: (async () => ({
        ok: false,
        status: 403,
        message: "admin role required",
      })) as never,
    },
  );
  const response = await handler(request());
  assertEquals(response.status, 403);
  assertEquals(await response.json(), { error: "admin role required" });
});
