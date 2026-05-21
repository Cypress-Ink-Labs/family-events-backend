import type { SupabaseClient } from "@supabase/supabase-js";

export interface EnqueueSourceScrapeResult {
  queue_id: number | null;
  deduped: boolean;
}

export interface SourceScrapeEnqueueResponseRow
  extends EnqueueSourceScrapeResult {
  source_id: string;
}

export function buildScrapeSourceResponse(
  results: SourceScrapeEnqueueResponseRow[],
) {
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
  const { data: inserted, error: insertError } = await supabase
    .from("source_scrape_queue")
    .insert({ source_id: sourceId, trigger_type: triggerType })
    .select("id")
    .maybeSingle();

  if (!insertError && inserted) {
    return {
      queue_id: Number((inserted as { id: number }).id),
      deduped: false,
    };
  }

  const { data: existing, error: selectError } = await supabase
    .from("source_scrape_queue")
    .select("id")
    .eq("source_id", sourceId)
    .in("status", ["pending", "processing", "retrying"])
    .order("enqueued_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (selectError) throw selectError;
  return {
    queue_id: existing ? Number((existing as { id: number }).id) : null,
    deduped: true,
  };
}

export async function kickProcessSourceQueue(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<void> {
  const response = await fetch(
    `${supabaseUrl}/functions/v1/process-source-queue`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: "{}",
    },
  );

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(
      `process-source-queue ${response.status}: ${body.slice(0, 200)}`,
    );
  }
}
