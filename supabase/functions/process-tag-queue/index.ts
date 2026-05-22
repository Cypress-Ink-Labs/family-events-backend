import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { requireServiceRole } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, errorMessage, logEdgeEvent } from "../_shared/logger.ts";
import {
  resolveCompletedTagQueueStatus,
  shouldStopBeforeStartingNextTagRow,
} from "./queue-policy.ts";

// Retry policy (chosen in plan):
//   - exponential backoff (1, 2, 4, 8, 16 min) via next_attempt_at
//   - dead-letter after MAX_ATTEMPTS=5
//   - Sentry on dead-letter only (avoid noise from transient OpenAI 5xx)
const MAX_ATTEMPTS = 5;
const BASE_BACKOFF_MS = 60_000;
// Stay well under Supabase edge function 150s wall. Per-event work is a
// single LLM call (qwen3:1.7b ~5-15s on CPU) plus a few DB round-trips —
// independent across rows. Process the claim batch in CONCURRENCY-sized
// parallel chunks via Promise.all so wall scales with chunk count, not
// batch count. Ollama serves concurrent requests fine; the bottleneck was
// the serial JS loop, not the model.
//
// Old: BATCH_SIZE=4 serial → 4 events / ~60s = 240/hr.
// New: BATCH_SIZE=16, CONCURRENCY=4 → 16 events / ~60s = 960/hr (4x).
const BATCH_SIZE = 16;
const CONCURRENCY = 4;
const PER_ITEM_TIMEOUT_MS = 60_000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

interface QueueRow {
  id: number;
  event_id: string;
  source_run_id: string | null;
  trigger_type: "import" | "reclassify" | "manual-review";
  attempt_count: number;
}

interface ProcessSummary {
  claimed: number;
  reaped: number;
  succeeded: number;
  failed: number;
  dead: number;
  pending_after: number | null;
  duration_ms: number;
}

async function fetchEventInputs(
  supabase: SupabaseClient,
  eventId: string,
): Promise<{ title: string; description: string } | null> {
  const { data, error } = await supabase
    .from("events")
    .select("title, description")
    .eq("id", eventId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return {
    title: String((data as { title?: unknown }).title ?? ""),
    description: String((data as { description?: unknown }).description ?? ""),
  };
}

async function callTagEvent(
  supabaseUrl: string,
  serviceRoleKey: string,
  row: QueueRow,
  inputs: { title: string; description: string },
): Promise<void> {
  const response = await fetch(`${supabaseUrl}/functions/v1/tag-event`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${serviceRoleKey}`,
    },
    body: JSON.stringify({
      event_id: row.event_id,
      source_run_id: row.source_run_id,
      trigger_type: row.trigger_type,
      title: inputs.title,
      description: inputs.description,
    }),
    signal: AbortSignal.timeout(PER_ITEM_TIMEOUT_MS),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`tag-event ${response.status}: ${body.slice(0, 200)}`);
  }
}

async function markSuccess(
  supabase: SupabaseClient,
  rowId: number,
): Promise<void> {
  const { error } = await supabase
    .from("event_tag_queue")
    .update({
      status: resolveCompletedTagQueueStatus(),
      finished_at: new Date().toISOString(),
      last_error: null,
    })
    .eq("id", rowId);
  if (error) throw error;
}

async function markFailureOrDead(
  supabase: SupabaseClient,
  row: QueueRow,
  err: unknown,
): Promise<{ dead: boolean }> {
  const errMsg = errorMessage(err);
  const attempts = row.attempt_count; // already incremented by claim_tag_queue_batch
  const isDead = attempts >= MAX_ATTEMPTS;

  if (isDead) {
    const { error } = await supabase
      .from("event_tag_queue")
      .update({
        status: "dead",
        finished_at: new Date().toISOString(),
        last_error: errMsg.slice(0, 1000),
      })
      .eq("id", row.id);
    if (error) throw error;
    return { dead: true };
  }

  // Exponential backoff. attempts=1 → 1 min, attempts=2 → 2 min, … attempts=4 → 8 min.
  const backoffMs = BASE_BACKOFF_MS * Math.pow(2, attempts - 1);
  const nextAttemptAt = new Date(Date.now() + backoffMs).toISOString();
  const { error } = await supabase
    .from("event_tag_queue")
    .update({
      status: "pending",
      started_at: null,
      next_attempt_at: nextAttemptAt,
      last_error: errMsg.slice(0, 1000),
    })
    .eq("id", row.id);
  if (error) throw error;
  return { dead: false };
}

export async function processBatch(
  supabase: SupabaseClient,
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<ProcessSummary> {
  const batchStart = Date.now();
  const summary: ProcessSummary = {
    claimed: 0,
    reaped: 0,
    succeeded: 0,
    failed: 0,
    dead: 0,
    pending_after: null,
    duration_ms: 0,
  };

  const { data: reaped, error: reapError } = await supabase.rpc(
    "reap_stuck_tag_queue_rows",
  );
  if (reapError) throw reapError;
  summary.reaped = Number(reaped ?? 0);

  const { data: claimed, error: claimError } = await supabase.rpc(
    "claim_tag_queue_batch",
    {
      p_limit: BATCH_SIZE,
    },
  );
  if (claimError) throw claimError;

  const rows = (claimed ?? []) as QueueRow[];
  summary.claimed = rows.length;
  if (rows.length === 0) {
    summary.duration_ms = Date.now() - batchStart;
    logEdgeEvent("log", "tag-queue batch done", {
      function: "process-tag-queue",
      ...summary,
    });
    return summary;
  }

  // Process each row in an isolated try/catch so a single failure doesn't
  // poison its chunk. Returned to the caller as an awaitable for Promise.all.
  async function processOneRow(row: QueueRow): Promise<void> {
    const rowStart = Date.now();
    let activeRow = row;
    try {
      const { data: startedRow, error: startedError } = await supabase.rpc(
        "mark_tag_queue_row_started",
        { p_queue_id: row.id },
      );
      if (startedError) throw startedError;
      activeRow = {
        ...row,
        attempt_count: Number(
          (startedRow as { attempt_count?: unknown } | null)?.attempt_count ??
            row.attempt_count + 1,
        ),
      };

      const inputs = await fetchEventInputs(supabase, activeRow.event_id);
      if (!inputs || !inputs.title) {
        // Event was deleted between enqueue and claim, or has no title.
        // Don't retry — mark as a soft completion.
        await markSuccess(supabase, activeRow.id);
        summary.succeeded += 1;
        logEdgeEvent("log", "tag-queue row skipped (event missing)", {
          function: "process-tag-queue",
          queue_row_id: activeRow.id,
          event_id: activeRow.event_id,
          attempt: activeRow.attempt_count,
          duration_ms: Date.now() - rowStart,
          outcome: "skipped-missing-event",
        });
        return;
      }

      await callTagEvent(supabaseUrl, serviceRoleKey, activeRow, inputs);
      await markSuccess(supabase, activeRow.id);
      summary.succeeded += 1;
      logEdgeEvent("log", "tag-queue row processed", {
        function: "process-tag-queue",
        queue_row_id: activeRow.id,
        event_id: activeRow.event_id,
        attempt: activeRow.attempt_count,
        duration_ms: Date.now() - rowStart,
        title_chars: inputs.title.length,
        description_chars: inputs.description.length,
        outcome: "succeeded",
      });
    } catch (err) {
      const { dead } = await markFailureOrDead(supabase, activeRow, err).catch(
        (markErr) => {
          // Updating the row itself failed — log loudly so we notice in Sentry.
          void captureEdgeException(
            markErr,
            errorContext(markErr, {
              function: "process-tag-queue",
              queue_row_id: activeRow.id,
              event_id: activeRow.event_id,
              stage: "mark-failure",
            }),
          );
          return { dead: false };
        },
      );

      if (dead) {
        summary.dead += 1;
        await captureEdgeException(
          err,
          errorContext(err, {
            function: "process-tag-queue",
            queue_row_id: activeRow.id,
            event_id: activeRow.event_id,
            attempts: activeRow.attempt_count,
            status: "dead",
          }),
        );
        logEdgeEvent(
          "error",
          "tag-queue row dead-lettered",
          errorContext(err, {
            function: "process-tag-queue",
            queue_row_id: activeRow.id,
            event_id: activeRow.event_id,
            attempts: activeRow.attempt_count,
            duration_ms: Date.now() - rowStart,
            outcome: "dead",
          }),
        );
      } else {
        summary.failed += 1;
        // Transient failures intentionally NOT captured to Sentry to avoid
        // noise during OpenAI/edge outages. The queue_row itself preserves
        // last_error for inspection.
        logEdgeEvent("warn", "tag-queue row retry scheduled", {
          function: "process-tag-queue",
          queue_row_id: activeRow.id,
          event_id: activeRow.event_id,
          attempt: activeRow.attempt_count,
          duration_ms: Date.now() - rowStart,
          error: errorMessage(err).slice(0, 300),
          outcome: "retry",
        });
      }
    }
  }

  // Run CONCURRENCY rows in parallel per chunk. Each row is its own LLM call
  // + ~3 DB round-trips and is fully independent — Promise.all serializes
  // the wait, not the work. The wall budget check runs before each chunk so
  // we release the rest of the batch if a previous chunk took unexpectedly
  // long, instead of starting more LLM calls we can't finish.
  for (let i = 0; i < rows.length; i += CONCURRENCY) {
    if (shouldStopBeforeStartingNextTagRow(Date.now() - batchStart, 110_000)) {
      const unstartedRowIds = rows.slice(i).map((item) => item.id);
      if (unstartedRowIds.length > 0) {
        await supabase.rpc("release_unstarted_tag_queue_rows", {
          p_claimed_ids: unstartedRowIds,
        });
      }
      break;
    }
    const chunk = rows.slice(i, i + CONCURRENCY);
    await Promise.all(chunk.map((row) => processOneRow(row)));
  }

  // Snapshot queue depth after the batch so dashboards aren't the only signal.
  const { count: depth } = await supabase
    .from("event_tag_queue")
    .select("id", { count: "exact", head: true })
    .eq("status", "pending");

  summary.pending_after = depth ?? null;
  summary.duration_ms = Date.now() - batchStart;

  logEdgeEvent("log", "tag-queue batch done", {
    function: "process-tag-queue",
    ...summary,
  });

  return summary;
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
      const supabase = createClient(supabaseUrl, serviceRoleKey);
      const summary = await processBatch(supabase, supabaseUrl, serviceRoleKey);
      // Batch-done log emitted from inside processBatch w/ pending_after depth.
      return new Response(JSON.stringify(summary), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (err) {
      await captureEdgeException(
        err,
        errorContext(err, { function: "process-tag-queue", stage: "outer" }),
      );
      logEdgeEvent(
        "error",
        "process-tag-queue outer failure",
        errorContext(err, { function: "process-tag-queue" }),
      );
      return new Response(JSON.stringify({ error: String(err) }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  });
}
