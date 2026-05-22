import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "@supabase/supabase-js"
import { requireServiceRole } from "../_shared/auth.ts"
import { errorMessage } from "../_shared/logger.ts"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders })
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""

  const auth = requireServiceRole(req, serviceRoleKey)
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  try {
    const { label, status, http_status, duration_s, body } = await req.json()

    if (!label || !status) {
      return new Response(JSON.stringify({ error: "label and status are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey)
    const { error } = await supabase.rpc("log_railway_cron_run", {
      p_label: String(label),
      p_status: String(status),
      p_http_status: http_status ?? null,
      p_duration_s: duration_s ?? null,
      p_body: body ? String(body) : null,
    })
    if (error) throw error

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  } catch (err) {
    return new Response(JSON.stringify({ error: errorMessage(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
})
