import "@supabase/functions-js/edge-runtime.d.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";
import { embedEvent, type EmbedEventDeps } from "../embed-event/handler.ts";
import { logEdgeEvent } from "../_shared/logger.ts";

// ── Constants ────────────────────────────────────────────────────────────────

const BATCH_SIZE = 50;
const DELAY_BETWEEN_ITEMS_MS = 50; // ~1200/min, well under OpenAI 3000 RPM
const BUDGET_MS = 110_000; // Stop before edge function 150s wall limit

// ── Types ────────────────────────────────────────────────────────────────────

interface BackfillSummary {
  total_found: number;
  processed: number;
  failed: number;
  skipped: number;
  duration_ms: number;
}

interface EventRow {
  id: string;
  title: string;
  description: string | null;
}

// ── Core logic ───────────────────────────────────────────────────────────────

async function findEventsWithoutEmbeddings(
  supabase: SupabaseClient,
  limit: number,
): Promise<EventRow[]> {
  // Use a raw SQL query via rpc or a left-join-aware select.
  // Supabase JS doesn't support LEFT JOIN directly, so we use a NOT IN subquery approach.
  const { data: embeddedIds, error: embError } = await supabase
    .from("event_embeddings")
    .select("event_id");

  if (embError) throw embError;

  const excludeIds = (embeddedIds ?? []).map(
    (row: { event_id: string }) => row.event_id,
  );

  // Fetch events not in the embedded set
  let query = supabase
    .from("events")
    .select("id, title, description")
    .order("created_at", { ascending: true })
    .limit(limit);

  // If we have existing embeddings, exclude them
  if (excludeIds.length > 0) {
    // Use .not('id', 'in', ...) for exclusion. For large sets this could be
    // slow — but at our scale (< 10K events) it's fine. For production scale
    // we'd use an RPC with a proper LEFT JOIN.
    query = query.not("id", "in", `(${excludeIds.join(",")})`);
  }

  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []) as EventRow[];
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function backfillEmbeddings(
  supabase: SupabaseClient,
  openAiApiKey: string,
  options?: {
    batchSize?: number;
    delayMs?: number;
    budgetMs?: number;
    fetchImpl?: typeof fetch;
    now?: () => number;
  },
): Promise<BackfillSummary> {
  const batchSize = options?.batchSize ?? BATCH_SIZE;
  const delayMs = options?.delayMs ?? DELAY_BETWEEN_ITEMS_MS;
  const budgetMs = options?.budgetMs ?? BUDGET_MS;
  const startedAt = options?.now?.() ?? Date.now();

  const summary: BackfillSummary = {
    total_found: 0,
    processed: 0,
    failed: 0,
    skipped: 0,
    duration_ms: 0,
  };

  const events = await findEventsWithoutEmbeddings(supabase, batchSize);
  summary.total_found = events.length;

  if (events.length === 0) {
    summary.duration_ms = (options?.now?.() ?? Date.now()) - startedAt;
    logEdgeEvent("log", "backfill-embeddings: nothing to do", {
      function: "backfill-embeddings",
      ...summary,
    });
    return summary;
  }

  const deps: EmbedEventDeps = {
    supabase,
    openAiApiKey,
    fetchImpl: options?.fetchImpl,
  };

  for (const event of events) {
    const elapsed = (options?.now?.() ?? Date.now()) - startedAt;
    if (elapsed >= budgetMs) {
      logEdgeEvent("warn", "backfill-embeddings: budget exhausted", {
        function: "backfill-embeddings",
        elapsed_ms: elapsed,
        processed: summary.processed,
        remaining: summary.total_found - summary.processed - summary.failed - summary.skipped,
      });
      break;
    }

    if (!event.title?.trim()) {
      summary.skipped += 1;
      continue;
    }

    try {
      await embedEvent(
        {
          event_id: event.id,
          title: event.title,
          description: event.description,
        },
        deps,
      );
      summary.processed += 1;
    } catch (err) {
      summary.failed += 1;
      logEdgeEvent("warn", "backfill-embeddings: item failed", {
        function: "backfill-embeddings",
        event_id: event.id,
        error: err instanceof Error ? err.message : String(err),
      });
    }

    // Rate limit delay between items
    if (delayMs > 0) {
      await sleep(delayMs);
    }
  }

  summary.duration_ms = (options?.now?.() ?? Date.now()) - startedAt;

  logEdgeEvent("log", "backfill-embeddings: batch complete", {
    function: "backfill-embeddings",
    ...summary,
  });

  return summary;
}

// ── Edge function entry point ────────────────────────────────────────────────

if (import.meta.main) {
  serveServiceRoleJson(
    { functionName: "backfill-embeddings", errorStage: "outer" },
    async ({ supabase }) => {
      const openAiApiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
      if (!openAiApiKey) {
        return { error: "OPENAI_API_KEY not configured", processed: 0 };
      }
      return backfillEmbeddings(supabase, openAiApiKey);
    },
  );
}
