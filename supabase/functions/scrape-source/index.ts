import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { requireAdminOrService } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, logEdgeEvent } from "../_shared/logger.ts";
import {
  buildScrapeSourceResponse,
  enqueueSourceScrape,
  kickProcessSourceQueue,
  type SourceScrapeEnqueueResponseRow,
} from "./lib/source-queue.ts";
import type { EventSourceRow } from "./lib/types.ts";

const DEFAULT_ALLOWED_ORIGINS = [
  "https://family-events.org",
  "https://www.family-events.org",
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

declare const EdgeRuntime:
  | { waitUntil<T>(promise: Promise<T>): Promise<T> }
  | undefined;

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

function dueSourceLimit(): number {
  const parsed = Number(Deno.env.get("DUE_SOURCE_LIMIT") ?? "200");
  if (!Number.isFinite(parsed)) return 200;
  return Math.max(1, Math.min(Math.floor(parsed), 500));
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

    let sourcesRaw: unknown[] | null = null;
    let sourceError: unknown = null;

    if (requestedSourceId) {
      const response = await supabase.from("event_sources").select("*").eq(
        "is_active",
        true,
      ).eq("id", requestedSourceId);
      sourcesRaw = response.data;
      sourceError = response.error;
    } else {
      const response = await supabase.rpc("due_event_sources", {
        p_limit: dueSourceLimit(),
      });
      sourcesRaw = response.data;
      sourceError = response.error;
    }

    if (sourceError) {
      throw sourceError;
    }

    const dueSources = (sourcesRaw ?? []) as EventSourceRow[];
    const results: SourceScrapeEnqueueResponseRow[] = [];

    for (const source of dueSources) {
      const enqueue = await enqueueSourceScrape(
        supabase,
        source.id,
        requestedSourceId ? "manual" : "scheduled",
      );
      await supabase
        .from("event_sources")
        .update({ last_status: "pending" })
        .eq("id", source.id);
      results.push({
        source_id: source.id,
        queue_id: enqueue.queue_id,
        deduped: enqueue.deduped,
      });
    }

    if (results.length > 0 && supabaseUrl && serviceRoleKey) {
      const kick = kickProcessSourceQueue(supabaseUrl, serviceRoleKey).catch(
        (err) => {
          logEdgeEvent(
            "warn",
            "source-queue kick failed",
            errorContext(err, {
              function: "scrape-source",
              stage: "kick-source",
            }),
          );
        },
      );
      if (typeof EdgeRuntime !== "undefined") {
        EdgeRuntime.waitUntil(kick);
      }
    }

    return new Response(
      JSON.stringify(buildScrapeSourceResponse(results)),
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
