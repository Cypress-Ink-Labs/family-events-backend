import { createClient, type SupabaseClient } from "@supabase/supabase-js"
import { requireServiceRole } from "./auth.ts"
import { buildCorsHeaders, resolveAllowedOrigin } from "./cors.ts"
import { errorContext } from "./logger.ts"
import { captureEdgeException } from "./sentry.ts"

interface ServiceRoleJsonContext {
  request: Request
  serviceRoleKey: string
  supabase: SupabaseClient
  supabaseUrl: string
}

interface ServiceRoleJsonOptions {
  errorStage?: string
  functionName: string
}

type ServiceRoleJsonHandler = (context: ServiceRoleJsonContext) => Promise<unknown>

export class ServiceRoleJsonError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
    this.name = "ServiceRoleJsonError"
  }
}

export function serviceRoleJsonError(status: number, message: string) {
  return new ServiceRoleJsonError(status, message)
}

function jsonResponse(body: unknown, status = 200, corsHeaders: Record<string, string>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

export function serveServiceRoleJson(
  { errorStage = "handler", functionName }: ServiceRoleJsonOptions,
  handler: ServiceRoleJsonHandler
) {
  Deno.serve(async (req: Request) => {
    const allowedOrigin = resolveAllowedOrigin(req.headers.get("Origin"))
    const corsHeaders = buildCorsHeaders(allowedOrigin, ["POST", "OPTIONS"])

    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders })
    }

    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""

    if (!serviceRoleKey) {
      return jsonResponse({ error: "SUPABASE_SERVICE_ROLE_KEY not configured" }, 500, corsHeaders)
    }

    const auth = requireServiceRole(req, serviceRoleKey)
    if (!auth.ok) {
      return jsonResponse({ error: auth.message }, auth.status, corsHeaders)
    }

    if (!supabaseUrl) {
      return jsonResponse({ error: "SUPABASE_URL not configured" }, 500, corsHeaders)
    }

    try {
      const supabase = createClient(supabaseUrl, serviceRoleKey)
      return jsonResponse(
        await handler({ request: req, serviceRoleKey, supabase, supabaseUrl }),
        200,
        corsHeaders
      )
    } catch (err) {
      if (err instanceof ServiceRoleJsonError) {
        return jsonResponse({ error: err.message }, err.status, corsHeaders)
      }
      await captureEdgeException(
        err,
        errorContext(err, { function: functionName, stage: errorStage })
      )
      // Do not leak DB/PostgREST detail (code=/details=) to callers. Full detail
      // is logged + sent to Sentry above; the client gets a correlation id.
      return jsonResponse(
        { error: "Internal error", executionId: Deno.env.get("SB_EXECUTION_ID") ?? null },
        500,
        corsHeaders
      )
    }
  })
}
