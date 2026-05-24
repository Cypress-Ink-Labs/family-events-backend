import { type SupabaseClient } from "@supabase/supabase-js";
import {
  type CronRunContext,
  cronRunContextFromRequest,
  logCronRunEvent,
} from "../_shared/cron-run-log.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, errorMessage } from "../_shared/logger.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";
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
// CONCURRENCY must match the Ollama OLLAMA_NUM_PARALLEL env in
// apps/qwen-ollama/Dockerfile. Exceeding it queues requests inside Ollama
// past tag-event's 45s edge timeout. Bump in both places together.
const BATCH_SIZE = 20;
const CONCURRENCY = 4;
const PER_ITEM_TIMEOUT_MS = 60_000;

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

export async function processTagQueueBatch(
  supabase: SupabaseClient,
  supabaseUrl: string,
  serviceRoleKey: string,
  cronContext: CronRunContext = { runKey: null, label: null },
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
    await logCronRunEvent(
      supabase,
      cronContext,
      "log",
      "tag-queue batch done",
      {
        function: "process-tag-queue",
        ...summary,
      },
    );
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
        await logCronRunEvent(
          supabase,
          cronContext,
          "log",
          "tag-queue row skipped (event missing)",
          {
            function: "process-tag-queue",
            queue_row_id: activeRow.id,
            event_id: activeRow.event_id,
            attempt: activeRow.attempt_count,
            duration_ms: Date.now() - rowStart,
            outcome: "skipped-missing-event",
          },
        );
        return;
      }

      await callTagEvent(supabaseUrl, serviceRoleKey, activeRow, inputs);
      await markSuccess(supabase, activeRow.id);
      summary.succeeded += 1;
      await logCronRunEvent(
        supabase,
        cronContext,
        "log",
        "tag-queue row processed",
        {
          function: "process-tag-queue",
          queue_row_id: activeRow.id,
          event_id: activeRow.event_id,
          attempt: activeRow.attempt_count,
          duration_ms: Date.now() - rowStart,
          title_chars: inputs.title.length,
          description_chars: inputs.description.length,
          outcome: "succeeded",
        },
      );
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
        await logCronRunEvent(
          supabase,
          cronContext,
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
        await logCronRunEvent(
          supabase,
          cronContext,
          "warn",
          "tag-queue row retry scheduled",
          {
            function: "process-tag-queue",
            queue_row_id: activeRow.id,
            event_id: activeRow.event_id,
            attempt: activeRow.attempt_count,
            duration_ms: Date.now() - rowStart,
            error: errorMessage(err).slice(0, 300),
            outcome: "retry",
          },
        );
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

  await logCronRunEvent(supabase, cronContext, "log", "tag-queue batch done", {
    function: "process-tag-queue",
    ...summary,
  });

  // Self-chain: if work remains AND we actually got through some this tick,
  // fire-and-forget invoke_process_tag_queue (net.http_post) to trigger the
  // next batch immediately. Bypasses Railway's hard 5-min minimum cron
  // interval so the queue drains at edge-fn speed, not at cron cadence.
  //
  // Guards against runaway:
  //   - require pending_after > 0 (no work → stop chain)
  //   - require claimed > 0 (no progress this tick → stop chain, let cron retry)
  //   - require failed < claimed (don't loop on persistent errors)
  if (
    (summary.pending_after ?? 0) > 0 &&
    summary.claimed > 0 &&
    summary.failed < summary.claimed
  ) {
    const { error: chainError } = await supabase.rpc(
      "invoke_process_tag_queue",
    );
    if (chainError) {
      await logCronRunEvent(
        supabase,
        cronContext,
        "warn",
        "tag-queue self-chain kick failed",
        {
          function: "process-tag-queue",
          pending_after: summary.pending_after,
          error: chainError.message,
        },
      );
    }
  }

  return summary;
}

if (import.meta.main) {
  serveServiceRoleJson(
    { functionName: "process-tag-queue", errorStage: "outer" },
    ({ request, serviceRoleKey, supabase, supabaseUrl }) =>
      processTagQueueBatch(
        supabase,
        supabaseUrl,
        serviceRoleKey,
        cronRunContextFromRequest(request),
      ),
  );
}
