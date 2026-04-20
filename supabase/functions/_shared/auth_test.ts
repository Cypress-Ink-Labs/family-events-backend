import type { SupabaseClient } from "@supabase/supabase-js"

import { requireAdminOrService } from "./auth.ts"

function assert(condition: boolean, message = "Assertion failed"): void {
  if (!condition) {
    throw new Error(message)
  }
}

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

function makeRequest(token: string): Request {
  return new Request("https://example.local/functions/v1/scrape-source", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })
}

function makeServiceClient(role: "admin" | "user"): SupabaseClient {
  return {
    from() {
      return {
        select() {
          return {
            eq() {
              return {
                maybeSingle: async () => ({ data: { role }, error: null }),
              }
            },
          }
        },
      }
    },
  } as unknown as SupabaseClient
}

function makeUserClient(userId: string | null, error: Error | null = null) {
  return {
    auth: {
      getUser: async () => ({
        data: { user: userId ? { id: userId } : null },
        error,
      }),
    },
  }
}

if (typeof Deno !== "undefined") {
  Deno.test("requireAdminOrService accepts sb_secret bearer tokens as service auth", async () => {
    const serviceKey = "sb_secret_very_secret_value_123"

    const result = await requireAdminOrService(
      makeRequest(serviceKey),
      makeServiceClient("admin"),
      "https://project.supabase.co",
      serviceKey,
      "anon-key"
    )

    assertEquals(result, { ok: true, source: "service_role", userId: null })
  })

  Deno.test("requireAdminOrService rejects invalid sb_secret bearer tokens", async () => {
    const serviceKey = "sb_secret_expected_key"

    const result = await requireAdminOrService(
      makeRequest("sb_secret_wrong_key"),
      makeServiceClient("admin"),
      "https://project.supabase.co",
      serviceKey,
      "anon-key",
      () => makeUserClient(null, new Error("invalid JWT"))
    )

    assertEquals(result, { ok: false, status: 401, message: "invalid or expired token" })
  })

  Deno.test("requireAdminOrService keeps legacy JWT service key compatibility", async () => {
    const legacyServiceRoleKey =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzZXJ2aWNlX3JvbGUifQ.signature"

    const result = await requireAdminOrService(
      makeRequest(legacyServiceRoleKey),
      makeServiceClient("admin"),
      "https://project.supabase.co",
      legacyServiceRoleKey,
      "anon-key"
    )

    assertEquals(result, { ok: true, source: "service_role", userId: null })
  })

  Deno.test("requireAdminOrService rejects non-admin users after JWT authentication", async () => {
    const serviceKey = "sb_secret_expected_key"

    const result = await requireAdminOrService(
      makeRequest("eyJhbGciOiJIUzI1NiJ9.user.jwt"),
      makeServiceClient("user"),
      "https://project.supabase.co",
      serviceKey,
      "anon-key",
      () => makeUserClient("user-123")
    )

    assertEquals(result, { ok: false, status: 403, message: "admin role required" })
  })

  Deno.test("requireAdminOrService uses the injected user client factory for JWT auth", async () => {
    let called = false

    await requireAdminOrService(
      makeRequest("eyJhbGciOiJIUzI1NiJ9.user.jwt"),
      makeServiceClient("admin"),
      "https://project.supabase.co",
      "sb_secret_expected_key",
      "anon-key",
      () => {
        called = true
        return makeUserClient("admin-123")
      }
    )

    assert(called, "Expected injected user client factory to be called")
  })
}
