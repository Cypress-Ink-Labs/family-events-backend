import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { requireServiceRole } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, logEdgeEvent } from "../_shared/logger.ts";
import {
  planSourceQueueClaimHandling,
  processQueueRow,
  reapStuckSourceQueueRows,
  type SourceQueueRow,
} from "./lib/worker.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

function sourceClaimLimit(): number {
  return 1;
}

export async function processSourceQueueBatch(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<{
  claimed: number;
  started: number;
  released: number;
  reaped: number;
  outcome: string | null;
}> {
  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const workerStartedAt = Date.now();
  const reaped = await reapStuckSourceQueueRows(supabase);

  const { data: claimed, error: claimError } = await supabase.rpc(
    "claim_source_scrape_queue_batch",
    { p_limit: sourceClaimLimit() },
  );
  if (claimError) throw claimError;

  const rows = (claimed ?? []) as SourceQueueRow[];
  const plan = planSourceQueueClaimHandling(
    rows.map((row) => row.id),
    Date.now() - workerStartedAt,
  );

  if (plan.release.length > 0) {
    await supabase.rpc("release_unstarted_source_scrape_queue_rows", {
      p_claimed_ids: plan.release,
    });
  }

  if (plan.start == null) {
    return {
      claimed: rows.length,
      started: 0,
      released: plan.release.length,
      reaped,
      outcome: null,
    };
  }

  const row = rows.find((item) => item.id === plan.start);
  if (!row) {
    return {
      claimed: rows.length,
      started: 0,
      released: plan.release.length,
      reaped,
      outcome: null,
    };
  }

  const result = await processQueueRow(supabase, row);
  return {
    claimed: rows.length,
    started: 1,
    released: plan.release.length,
    reaped,
    outcome: result.outcome,
  };
}

if (import.meta.main) {
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
      const summary = await processSourceQueueBatch(
        supabaseUrl,
        serviceRoleKey,
      );
      logEdgeEvent("log", "source-queue batch done", {
        function: "process-source-queue",
        ...summary,
      });
      return new Response(JSON.stringify(summary), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (err) {
      await captureEdgeException(
        err,
        errorContext(err, { function: "process-source-queue", stage: "outer" }),
      );
      logEdgeEvent(
        "error",
        "process-source-queue outer failure",
        errorContext(err, { function: "process-source-queue" }),
      );
      return new Response(JSON.stringify({ error: String(err) }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  });
}
