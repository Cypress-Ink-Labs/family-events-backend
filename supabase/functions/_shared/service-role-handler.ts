import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { requireServiceRole } from "./auth.ts";
import { errorContext } from "./logger.ts";
import { captureEdgeException } from "./sentry.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

interface ServiceRoleJsonContext {
  request: Request;
  serviceRoleKey: string;
  supabase: SupabaseClient;
  supabaseUrl: string;
}

interface ServiceRoleJsonOptions {
  errorStage?: string;
  functionName: string;
}

type ServiceRoleJsonHandler = (
  context: ServiceRoleJsonContext,
) => Promise<unknown>;

export class ServiceRoleJsonError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ServiceRoleJsonError";
  }
}

export function serviceRoleJsonError(status: number, message: string) {
  return new ServiceRoleJsonError(status, message);
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: jsonHeaders,
  });
}

export function serveServiceRoleJson(
  { errorStage = "handler", functionName }: ServiceRoleJsonOptions,
  handler: ServiceRoleJsonHandler,
) {
  Deno.serve(async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders });
    }

    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";

    if (!serviceRoleKey) {
      return jsonResponse(
        { error: "SUPABASE_SERVICE_ROLE_KEY not configured" },
        500,
      );
    }

    const auth = requireServiceRole(req, serviceRoleKey);
    if (!auth.ok) {
      return jsonResponse({ error: auth.message }, auth.status);
    }

    if (!supabaseUrl) {
      return jsonResponse({ error: "SUPABASE_URL not configured" }, 500);
    }

    try {
      const supabase = createClient(supabaseUrl, serviceRoleKey);
      return jsonResponse(
        await handler({ request: req, serviceRoleKey, supabase, supabaseUrl }),
      );
    } catch (err) {
      if (err instanceof ServiceRoleJsonError) {
        return jsonResponse({ error: err.message }, err.status);
      }
      await captureEdgeException(
        err,
        errorContext(err, { function: functionName, stage: errorStage }),
      );
      // Do not leak DB/PostgREST detail (code=/details=) to callers. Full detail
      // is logged + sent to Sentry above; the client gets a correlation id.
      return jsonResponse(
        { error: "Internal error", executionId: Deno.env.get("SB_EXECUTION_ID") ?? null },
        500,
      );
    }
  });
}
