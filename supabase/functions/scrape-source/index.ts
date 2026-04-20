import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "@supabase/supabase-js"
import { requireAdminOrService } from "../_shared/auth.ts"
import { processSource } from "./lib/process-source.ts"
import { isSourceDue } from "./lib/schedule.ts"
import type { EventSourceRow, SourceResult } from "./lib/types.ts"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? ""
  const supabase = createClient(supabaseUrl, serviceRoleKey)

  // Auth: accept service role (cron) or admin user JWT. Reject everything else.
  const auth = await requireAdminOrService(req, supabase, supabaseUrl, serviceRoleKey, anonKey)
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  try {
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {}
    const requestedSourceId = typeof body?.source_id === "string" ? body.source_id : null

    let sourceQuery = supabase.from("event_sources").select("*").eq("is_active", true)
    if (requestedSourceId) {
      sourceQuery = sourceQuery.eq("id", requestedSourceId)
    }

    const { data: sourcesRaw, error: sourceError } = await sourceQuery
    if (sourceError) {
      throw sourceError
    }

    const sources = (sourcesRaw ?? []) as EventSourceRow[]
    const dueSources = requestedSourceId ? sources : sources.filter(isSourceDue)
    const results: SourceResult[] = []

    for (const source of dueSources) {
      const result = await processSource(supabase, source, supabaseUrl, serviceRoleKey)
      results.push(result)
    }

    return new Response(
      JSON.stringify({
        processed_sources: results.length,
        results,
      }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    )
  } catch (error) {
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : "Unexpected scrape failure.",
      }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    )
  }
})
