import "@supabase/functions-js/edge-runtime.d.ts";
import { type SupabaseClient } from "@supabase/supabase-js";
import { logEdgeEvent } from "../_shared/logger.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";
import {
  planSourceQueueClaimHandling,
  processSourceQueueRow,
  reapStuckSourceQueueRows,
  type SourceQueueRow,
} from "./lib/worker.ts";

function sourceClaimLimit(): number {
  return 1;
}

export async function processSourceQueueBatch(
  supabase: SupabaseClient,
): Promise<{
  claimed: number;
  started: number;
  released: number;
  reaped: number;
  outcome: string | null;
}> {
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

  const result = await processSourceQueueRow(supabase, row);
  return {
    claimed: rows.length,
    started: 1,
    released: plan.release.length,
    reaped,
    outcome: result.outcome,
  };
}

if (import.meta.main) {
  serveServiceRoleJson(
    { functionName: "process-source-queue", errorStage: "outer" },
    async ({ supabase }) => {
      const summary = await processSourceQueueBatch(supabase);
      logEdgeEvent("log", "source-queue batch done", {
        function: "process-source-queue",
        ...summary,
      });
      return summary;
    },
  );
}
