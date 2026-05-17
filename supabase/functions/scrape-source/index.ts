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
];

function buildCorsHeaders(origin: string | null): HeadersInit {
  const configured = Deno.env.get("ALLOWED_ORIGINS");
  const allowlist = (configured?.split(",") ?? DEFAULT_ALLOWED_ORIGINS)
    .map((value) => value.trim())
    .filter((value) => value.length > 0);
  const allowedOrigin = origin && allowlist.includes(origin)
    ? origin
    : allowlist[0] ?? "null";

  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    Vary: "Origin",
  };
}

Deno.serve(async (req: Request) => {
  const corsHeaders = buildCorsHeaders(req.headers.get("Origin"));

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
