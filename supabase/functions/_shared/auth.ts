import { createClient, type SupabaseClient } from "@supabase/supabase-js"

export type AuthResult =
  | { ok: true; source: "service_role" | "admin"; userId: string | null }
  | { ok: false; status: 401 | 403; message: string }

function extractBearer(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization")
  if (!header) return null
  const match = header.match(/^Bearer\s+(.+)$/i)
  return match ? match[1].trim() : null
}

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder()
  const bufA = enc.encode(a)
  const bufB = enc.encode(b)
  if (bufA.length !== bufB.length) return false
  let diff = 0
  for (let i = 0; i < bufA.length; i++) {
    diff |= bufA[i] ^ bufB[i]
  }
  return diff === 0
}

/**
 * Verify that the caller is either:
 *   1. Using the service role key (internal / cron calls), OR
 *   2. An authenticated user with role = 'admin' in user_profiles.
 *
 * Anything else is rejected (401 missing, 403 forbidden).
 *
 * Use this at the top of any edge function that mutates admin-owned data.
 */
export async function requireAdminOrService(
  req: Request,
  serviceClient: SupabaseClient,
  supabaseUrl: string,
  serviceRoleKey: string,
  anonKey: string
): Promise<AuthResult> {
  const token = extractBearer(req)
  if (!token) {
    return { ok: false, status: 401, message: "missing authorization header" }
  }

  if (timingSafeEqual(token, serviceRoleKey)) {
    return { ok: true, source: "service_role", userId: null }
  }

  // User-facing call: verify JWT and check role
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const {
    data: { user },
    error: userError,
  } = await userClient.auth.getUser()

  if (userError || !user) {
    return { ok: false, status: 401, message: "invalid or expired token" }
  }

  const { data: profile, error: profileError } = await serviceClient
    .from("user_profiles")
    .select("role")
    .eq("id", user.id)
    .maybeSingle()

  if (profileError) {
    return { ok: false, status: 403, message: "profile lookup failed" }
  }

  if (profile?.role !== "admin") {
    return { ok: false, status: 403, message: "admin role required" }
  }

  return { ok: true, source: "admin", userId: user.id }
}

/**
 * Verify that the caller is using the service role key. No user JWT accepted.
 * Use for functions that are only called internally (function-to-function, cron).
 */
export function requireServiceRole(req: Request, serviceRoleKey: string): AuthResult {
  const token = extractBearer(req)
  if (!token) {
    return { ok: false, status: 401, message: "missing authorization header" }
  }
  if (!timingSafeEqual(token, serviceRoleKey)) {
    return { ok: false, status: 403, message: "service role required" }
  }
  return { ok: true, source: "service_role", userId: null }
}
