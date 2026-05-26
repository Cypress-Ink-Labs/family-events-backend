import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export function createServiceClient(
  supabaseUrl: string,
  serviceRoleKey: string,
): SupabaseClient {
  return createClient(supabaseUrl, serviceRoleKey);
}

export function createAnonClient(
  supabaseUrl: string,
  anonKey: string,
  authorization?: string,
): SupabaseClient {
  return createClient(supabaseUrl, anonKey, {
    global: authorization
      ? { headers: { Authorization: authorization } }
      : undefined,
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
