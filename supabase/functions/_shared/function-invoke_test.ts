import { assertEquals } from "jsr:@std/assert";
import { invokeFunction } from "./function-invoke.ts";

Deno.test("invokeFunction posts service-role json to named edge function", async () => {
  let captured: { input: string | URL | Request; init?: RequestInit } | null =
    null;
  const result = await invokeFunction("target-fn", { ok: true }, {
    fetchImpl: (async (input, init) => {
      captured = { input, init };
      return new Response("response-body", { status: 202 });
    }) as typeof fetch,
    headers: { "X-Cron-Run-Key": "run-1" },
    serviceRoleKey: "service",
    supabaseUrl: "https://project.supabase.co/",
    truncateBodyAt: 8,
  });

  if (!captured) throw new Error("fetch was not called");
  const request = captured as { input: string | URL | Request; init?: RequestInit };
  assertEquals(
    String(request.input),
    "https://project.supabase.co/functions/v1/target-fn",
  );
  assertEquals(request.init?.method, "POST");
  assertEquals(
    (request.init?.headers as Record<string, string>).Authorization,
    "Bearer service",
  );
  assertEquals(
    (request.init?.headers as Record<string, string>)["Content-Type"],
    "application/json",
  );
  assertEquals(
    (request.init?.headers as Record<string, string>)["X-Cron-Run-Key"],
    "run-1",
  );
  assertEquals(request.init?.body, JSON.stringify({ ok: true }));
  assertEquals(result, {
    bodyText: "response-body",
    ok: true,
    status: 202,
    truncatedBodyText: "response",
  });
});
