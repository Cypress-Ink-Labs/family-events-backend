import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { requireServiceRole } from "./auth.ts";
import { errorContext, errorMessage } from "./logger.ts";
import { captureEdgeException } from "./sentry.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

interface ServiceRoleJsonContext {
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
) => Promise<Record<string, unknown>>;

function jsonResponse(body: Record<string, unknown>, status = 200) {
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
        await handler({ serviceRoleKey, supabase, supabaseUrl }),
      );
    } catch (err) {
      await captureEdgeException(
        err,
        errorContext(err, { function: functionName, stage: errorStage }),
      );
      return jsonResponse({ error: errorMessage(err) }, 500);
    }
  });
}
