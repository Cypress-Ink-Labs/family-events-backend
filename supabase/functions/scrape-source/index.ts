import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { requireAdminOrService } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, logEdgeEvent } from "../_shared/logger.ts";
import { processSource } from "./lib/process-source.ts";
import { isSourceDue } from "./lib/schedule.ts";
import type { EventSourceRow, SourceResult } from "./lib/types.ts";

const DEFAULT_ALLOWED_ORIGINS = [
  "https://family-events.up.railway.app",
  "http://localhost:5173",
  "http://localhost:5174",
  "http://localhost:5175",
  "http://127.0.0.1:5173",
  "http://127.0.0.1:5174",
  "http://127.0.0.1:5175",
];

function resolveAllowedOrigin(origin: string | null): string | null {
  const configured = Deno.env.get("ALLOWED_ORIGINS");
  const allowlist = (configured?.split(",") ?? DEFAULT_ALLOWED_ORIGINS)
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  if (!origin) return null;
  return allowlist.includes(origin) ? origin : null;
}

// Worker batch size (mirrors BATCH_SIZE in process-tag-queue). Kicking once per
// batch lets newly-imported events start tagging immediately instead of waiting
// up to a full cron tick (~60s). The Railway cron worker remains the safety net.
const TAG_QUEUE_BATCH_SIZE = 8;
const TAG_QUEUE_MAX_KICKS = 4;

declare const EdgeRuntime:
  | { waitUntil<T>(promise: Promise<T>): Promise<T> }
  | undefined;

function kickProcessTagQueue(
  supabaseUrl: string,
  serviceRoleKey: string,
  imported: number,
): void {
  const kicks = Math.min(
    TAG_QUEUE_MAX_KICKS,
    Math.max(1, Math.ceil(imported / TAG_QUEUE_BATCH_SIZE)),
  );
  const url = `${supabaseUrl}/functions/v1/process-tag-queue`;
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${serviceRoleKey}`,
  };

  for (let i = 0; i < kicks; i++) {
    const kick = fetch(url, { method: "POST", headers, body: "{}" })
      .then(async (res) => {
        if (!res.ok) {
          const body = await res.text().catch(() => "");
          throw new Error(
            `process-tag-queue ${res.status}: ${body.slice(0, 200)}`,
          );
        }
      })
      .catch((err) => {
        logEdgeEvent(
          "warn",
          "tag-queue kick failed",
          errorContext(err, { function: "scrape-source", stage: "kick" }),
        );
      });

    if (typeof EdgeRuntime !== "undefined") {
      EdgeRuntime.waitUntil(kick);
    }
  }
}

function buildCorsHeaders(allowedOrigin: string | null): HeadersInit {
  if (!allowedOrigin) return { Vary: "Origin" };

  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "Content-Type, Authorization, X-Client-Info, Apikey",
    Vary: "Origin",
  };
}

Deno.serve(async (req: Request) => {
  const allowedOrigin = resolveAllowedOrigin(req.headers.get("Origin"));
  const corsHeaders = buildCorsHeaders(allowedOrigin);

  if (req.headers.get("Origin") && !allowedOrigin) {
    return new Response(JSON.stringify({ error: "origin not allowed" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabase = createClient(supabaseUrl, serviceRoleKey);
  let requestedSourceId: string | null = null;
  const auth = await requireAdminOrService(
    req,
    supabase,
    supabaseUrl,
    serviceRoleKey,
    anonKey,
  );
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const body = req.method === "POST"
      ? await req.json().catch(() => ({}))
      : {};
    requestedSourceId = typeof body?.source_id === "string"
      ? body.source_id
      : null;

    let sourceQuery = supabase.from("event_sources").select("*").eq(
      "is_active",
      true,
    );
    if (requestedSourceId) {
      sourceQuery = sourceQuery.eq("id", requestedSourceId);
    }

    const { data: sourcesRaw, error: sourceError } = await sourceQuery;
    if (sourceError) {
      throw sourceError;
    }

    const sources = (sourcesRaw ?? []) as EventSourceRow[];
    const dueSources = requestedSourceId
      ? sources
      : sources.filter(isSourceDue);
    const results: SourceResult[] = [];

    for (const source of dueSources) {
      const result = await processSource(supabase, source);
      results.push(result);
    }

    const totalImported = results.reduce(
      (sum, r) => sum + r.eventsImported,
      0,
    );
    if (totalImported > 0 && supabaseUrl && serviceRoleKey) {
      kickProcessTagQueue(supabaseUrl, serviceRoleKey, totalImported);
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
      },
    );
  } catch (error) {
    await captureEdgeException(
      error,
      errorContext(error, {
        function: "scrape-source",
        source_id: requestedSourceId,
      }),
    );
    logEdgeEvent(
      "error",
      "scrape-source handler failed",
      errorContext(error, {
        function: "scrape-source",
        source_id: requestedSourceId,
      }),
    );

    return new Response(
      JSON.stringify({
        error: error instanceof Error
          ? error.message
          : "Unexpected scrape failure.",
      }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      },
    );
  }
});
