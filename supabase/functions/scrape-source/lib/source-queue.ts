import type { SupabaseClient } from "@supabase/supabase-js";
import { invokeFunction } from "../../_shared/function-invoke.ts";

export interface EnqueueSourceScrapeResult {
  queue_id: number | null;
  deduped: boolean;
}

export interface SourceScrapeEnqueueResponseRow extends EnqueueSourceScrapeResult {
  source_id: string;
}

export function buildScrapeSourceResponse(results: SourceScrapeEnqueueResponseRow[]) {
  return {
    processed_sources: results.length,
    results,
  };
}

export async function enqueueSourceScrape(
  supabase: SupabaseClient,
  sourceId: string,
  triggerType: "manual" | "bulk" | "scheduled" | "retry" = "manual",
): Promise<EnqueueSourceScrapeResult> {
  const { data, error } = await supabase
    .rpc("enqueue_source_scrape", {
      p_source_id: sourceId,
      p_trigger_type: triggerType,
    })
    .maybeSingle();

  if (error) throw error;

  const row = data as { queue_id: number | null; deduped: boolean } | null;
  return {
    queue_id: row?.queue_id == null ? null : Number(row.queue_id),
    deduped: row?.deduped ?? true,
  };
}

export async function kickProcessSourceQueue(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<void> {
  const response = await invokeFunction(
    "process-source-queue",
    {},
    {
      serviceRoleKey,
      supabaseUrl,
      timeoutMs: 5_000,
      truncateBodyAt: 200,
    },
  );

  if (!response.ok) {
    throw new Error(`process-source-queue ${response.status}: ${response.truncatedBodyText}`);
  }
}
