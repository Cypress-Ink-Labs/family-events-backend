import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { requireServiceRole } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, logEdgeEvent } from "../_shared/logger.ts";
import { kickProcessSourceQueue } from "../scrape-source/lib/source-queue.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

declare const EdgeRuntime:
  | { waitUntil<T>(promise: Promise<T>): Promise<T> }
  | undefined;

export function normalizeDueScrapePayload(
  value: unknown,
): { enqueued: number } {
  if (value && typeof value === "object" && "enqueued" in value) {
    return { enqueued: Number((value as { enqueued: unknown }).enqueued ?? 0) };
  }
  return { enqueued: 0 };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";

  const auth = requireServiceRole(req, serviceRoleKey);
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (!supabaseUrl) {
    return new Response(
      JSON.stringify({ error: "SUPABASE_URL not configured" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  try {
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const { data, error } = await supabase.rpc("run_due_source_scrapes");
    if (error) throw error;
    const kick = kickProcessSourceQueue(supabaseUrl, serviceRoleKey).catch(
      (kickError) => {
        logEdgeEvent(
          "warn",
          "source-queue safety kick failed",
          errorContext(kickError, {
            function: "scrape-due-sources",
            stage: "kick-source",
          }),
        );
      },
    );
    if (typeof EdgeRuntime !== "undefined") {
      EdgeRuntime.waitUntil(kick);
    } else {
      await kick;
    }
    logEdgeEvent("log", "scrape-due-sources dispatched", {
      function: "scrape-due-sources",
    });
    return new Response(JSON.stringify(normalizeDueScrapePayload(data)), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    await captureEdgeException(
      err,
      errorContext(err, { function: "scrape-due-sources", stage: "rpc" }),
    );
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
