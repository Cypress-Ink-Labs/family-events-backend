import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { requireAdminOrService } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, errorMessage, logEdgeEvent } from "../_shared/logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

const cronFunctionByLabel: Record<string, string> = {
  "cron-cleanup-stale": "cleanup-stale-runs",
  "cron-db-maintenance": "db-maintenance",
  "cron-enrich-events": "backfill-event-enrichment",
  "cron-review-events": "process-event-review-queue",
  "cron-scrape-sources": "scrape-due-sources",
  "cron-tag-queue": "process-tag-queue",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function truncateBody(body: string): string {
  return body.replaceAll(/\r?\n/g, " ").slice(0, 2000);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  if (!supabaseUrl) {
    return jsonResponse({ error: "SUPABASE_URL not configured" }, 500);
  }
  if (!serviceRoleKey) {
    return jsonResponse(
      { error: "SUPABASE_SERVICE_ROLE_KEY not configured" },
      500,
    );
  }
  if (!anonKey) {
    return jsonResponse({ error: "SUPABASE_ANON_KEY not configured" }, 500);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const auth = await requireAdminOrService(
    req,
    supabase,
    supabaseUrl,
    serviceRoleKey,
    anonKey,
  );
  if (!auth.ok) return jsonResponse({ error: auth.message }, auth.status);

  try {
    const body = await req.json().catch(() => ({}));
    const label = typeof body?.label === "string" ? body.label : "";
    const functionName = cronFunctionByLabel[label];
    if (!functionName) {
      return jsonResponse({ error: "unknown cron label" }, 400);
    }

    const startedAt = Date.now();
    const response = await fetch(
      `${supabaseUrl}/functions/v1/${functionName}`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${serviceRoleKey}`,
        },
        body: "{}",
      },
    );
    const durationSeconds = Math.max(
      0,
      Math.round((Date.now() - startedAt) / 1000),
    );
    const responseBody = truncateBody(await response.text());
    const status = response.ok ? "succeeded" : "failed";

    const { error: logError } = await supabase.rpc("log_railway_cron_run", {
      p_label: label,
      p_status: status,
      p_http_status: response.status,
      p_duration_s: durationSeconds,
      p_body: responseBody,
    });
    if (logError) throw logError;

    logEdgeEvent(response.ok ? "log" : "error", "admin cron run completed", {
      function: "admin-run-cron",
      label,
      target_function: functionName,
      http_status: response.status,
      duration_s: durationSeconds,
    });

    if (!response.ok) {
      return jsonResponse(
        {
          error: "cron run failed",
          label,
          http_status: response.status,
          body: responseBody,
        },
        502,
      );
    }

    return jsonResponse({
      ok: true,
      label,
      http_status: response.status,
      duration_s: durationSeconds,
      body: responseBody,
    });
  } catch (err) {
    await captureEdgeException(
      err,
      errorContext(err, { function: "admin-run-cron", stage: "handler" }),
    );
    return jsonResponse({ error: errorMessage(err) }, 500);
  }
});
