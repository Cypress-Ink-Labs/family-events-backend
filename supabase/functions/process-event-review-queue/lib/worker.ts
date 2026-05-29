import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type CronRunContext,
  logCronRunEvent,
} from "../../_shared/cron-run-log.ts";
import {
  type AppliedLlmEventReviewDecision,
  LLM_EVENT_REVIEW_DECISION,
  LLM_EVENT_REVIEW_STATUS,
  type LlmEventReviewDecision,
  type LlmReviewConfig,
  resolveLlmReviewConfig,
  reviewEventWithLlm,
  type ReviewMemoryContext,
} from "../../event-review/mod.ts";
import { errorMessage, logEdgeEvent } from "../../_shared/logger.ts";
import {
  fetchSimilarReviewContext,
  formatReviewMemoryPrompt,
  isMemoryFeatureEnabled,
} from "../../_shared/memory-context.ts";

const DEFAULT_BATCH_SIZE = 60;
const MAX_BATCH_SIZE = 100;
const BUDGET_MS = 110_000;
const REVIEWABLE_LLM_REVIEW_STATUS_PENDING = "pending";

export interface EventLlmReviewQueueRow {
  id: number;
  event_id: string;
  source_id: string | null;
  source_run_id: string | null;
  trigger_type: string;
  status: "pending" | "processing" | "retrying" | "succeeded" | "dead";
  attempt_count: number;
  max_attempts: number;
  next_attempt_at: string;
}

interface EventReviewRow {
  id: string;
  status: "draft" | "published" | "rejected" | "archived";
  title: string;
  description: string | null;
  start_datetime: string;
  end_datetime: string | null;
  timezone: string;
  venue_name: string | null;
  address: string | null;
  source_name: string | null;
  source_url: string | null;
  llm_review_status: string;
  llm_review_decision: string | null;
}

export interface ReviewQueueDeps {
  supabase: SupabaseClient;
  config: LlmReviewConfig;
  cronContext?: CronRunContext;
  now?: () => number;
  reviewEvent?: typeof reviewEventWithLlm;
}

export interface ReviewQueueBatchResult {
  claimed: number;
  reaped: number;
  succeeded: number;
  failed: number;
  retrying: number;
  dead: number;
  approved: number;
  rejected: number;
  needsAdminReview: number;
}

export interface EventReviewQueueRowResult {
  outcome: "succeeded" | "retrying" | "dead" | "skipped";
  appliedDecision: LlmEventReviewDecision | null;
  failed: boolean;
}

function nowIso(): string {
  return new Date().toISOString();
}

function resolveBatchSize(): number {
  const parsed = Number(
    Deno.env.get("LLM_REVIEW_BATCH_SIZE") ?? DEFAULT_BATCH_SIZE,
  );
  if (!Number.isFinite(parsed)) return DEFAULT_BATCH_SIZE;
  return Math.max(1, Math.min(Math.floor(parsed), MAX_BATCH_SIZE));
}

function shouldStopBeforeStartingNextRow(elapsedMs: number): boolean {
  return elapsedMs >= BUDGET_MS;
}

async function reapStuckRows(supabase: SupabaseClient): Promise<number> {
  const { data, error } = await supabase.rpc(
    "reap_stuck_event_llm_review_rows",
  );
  if (error) throw error;
  return Number(data ?? 0);
}

async function claimRows(
  supabase: SupabaseClient,
  limit: number,
): Promise<EventLlmReviewQueueRow[]> {
  const { data, error } = await supabase.rpc(
    "claim_event_llm_review_queue_batch",
    {
      p_limit: limit,
    },
  );
  if (error) throw error;
  return (data ?? []) as EventLlmReviewQueueRow[];
}

async function releaseUnstartedRows(
  supabase: SupabaseClient,
  rows: EventLlmReviewQueueRow[],
): Promise<void> {
  if (rows.length === 0) return;
  const { error } = await supabase.rpc(
    "release_unstarted_event_llm_review_rows",
    {
      p_claimed_ids: rows.map((row) => row.id),
    },
  );
  if (error) throw error;
}

async function markRowStarted(
  supabase: SupabaseClient,
  queueId: number,
): Promise<EventLlmReviewQueueRow> {
  const { data, error } = await supabase.rpc(
    "mark_event_llm_review_queue_row_started",
    { p_queue_id: queueId },
  );
  if (error) throw error;
  return data as EventLlmReviewQueueRow;
}

async function markQueueSucceeded(
  supabase: SupabaseClient,
  queueId: number,
): Promise<void> {
  const { error } = await supabase
    .from("event_llm_review_queue")
    .update({
      status: "succeeded",
      finished_at: nowIso(),
      last_error: null,
      updated_at: nowIso(),
    })
    .eq("id", queueId);
  if (error) throw error;
}

async function markQueueDead(
  supabase: SupabaseClient,
  queueId: number,
  reason: string,
): Promise<void> {
  const { error } = await supabase
    .from("event_llm_review_queue")
    .update({
      status: "dead",
      finished_at: nowIso(),
      last_error: reason.slice(0, 1000),
      updated_at: nowIso(),
    })
    .eq("id", queueId);
  if (error) throw error;
}

function backoffMs(attemptCount: number, baseMs: number): number {
  const exponent = Math.max(0, attemptCount - 1);
  return baseMs * Math.pow(2, exponent);
}

async function markQueueRetrying(
  supabase: SupabaseClient,
  row: EventLlmReviewQueueRow,
  reason: string,
  retryBaseMs: number,
): Promise<void> {
  const nextAttemptAt = new Date(
    Date.now() + backoffMs(row.attempt_count, retryBaseMs),
  )
    .toISOString();
  const { error } = await supabase
    .from("event_llm_review_queue")
    .update({
      status: "retrying",
      started_at: null,
      next_attempt_at: nextAttemptAt,
      last_error: reason.slice(0, 1000),
      updated_at: nowIso(),
    })
    .eq("id", row.id);
  if (error) throw error;
}

async function loadEvent(
  supabase: SupabaseClient,
  eventId: string,
): Promise<EventReviewRow | null> {
  const { data, error } = await supabase
    .from("events")
    .select(
      "id, status, title, description, start_datetime, end_datetime, timezone, venue_name, address, source_name, source_url, llm_review_status, llm_review_decision",
    )
    .eq("id", eventId)
    .maybeSingle();

  if (error) throw error;
  return (data ?? null) as EventReviewRow | null;
}

async function insertTrace(
  supabase: SupabaseClient,
  params: {
    queueRow: EventLlmReviewQueueRow;
    eventId: string;
    review: AppliedLlmEventReviewDecision;
    modelDecision: LlmEventReviewDecision | null;
    inputSnapshot: Record<string, unknown>;
    status: "succeeded" | "failed" | "skipped";
  },
): Promise<void> {
  const { error } = await supabase.from("event_llm_review_traces").insert({
    event_id: params.eventId,
    queue_id: params.queueRow.id,
    source_id: params.queueRow.source_id,
    source_run_id: params.queueRow.source_run_id,
    provider: params.review.provider,
    model: params.review.model,
    prompt_version: params.review.promptVersion,
    status: params.status,
    model_decision: params.modelDecision,
    applied_decision: params.review.appliedDecision,
    confidence: params.review.confidence,
    reason: params.review.reason,
    flags: params.review.flags,
    suggested_category: params.review.suggestedCategory,
    normalized_title: params.review.normalizedTitle,
    raw_response: params.review.rawResponse,
    error_code: params.review.errorCode,
    error_message: params.review.errorMessage,
    input_snapshot: params.inputSnapshot,
    processing_ms: params.review.processingMs,
  });

  if (error) throw error;
}

async function applyEventDecision(
  supabase: SupabaseClient,
  event: EventReviewRow,
  queueRow: EventLlmReviewQueueRow,
  review: AppliedLlmEventReviewDecision,
): Promise<boolean> {
  const { data, error } = await supabase.rpc(
    "apply_event_llm_review_decision",
    {
      p_queue_id: queueRow.id,
      p_event_id: event.id,
      p_source_id: queueRow.source_id,
      p_source_run_id: queueRow.source_run_id,
      p_provider: review.provider,
      p_model: review.model,
      p_prompt_version: review.promptVersion,
      p_review_status: review.status,
      p_model_decision: review.modelDecision,
      p_applied_decision: review.appliedDecision,
      p_confidence: review.confidence,
      p_reason: review.reason,
      p_flags: review.flags,
      p_suggested_category: review.suggestedCategory,
      p_normalized_title: review.normalizedTitle,
      p_raw_response: review.rawResponse,
      p_error_code: review.errorCode,
      p_error_message: review.errorMessage,
      p_input_snapshot: traceInputSnapshot(event),
      p_processing_ms: review.processingMs,
    },
  );
  if (error) throw error;
  return Boolean(data);
}

function buildSkippedReview(reason: string): AppliedLlmEventReviewDecision {
  return {
    status: LLM_EVENT_REVIEW_STATUS.FAILED,
    modelDecision: null,
    appliedDecision: LLM_EVENT_REVIEW_DECISION.NEEDS_ADMIN_REVIEW,
    confidence: null,
    reason,
    flags: ["skipped"],
    suggestedCategory: null,
    normalizedTitle: null,
    provider: null,
    model: null,
    promptVersion: "event-review-v1",
    rawResponse: null,
    errorCode: "skipped",
    errorMessage: reason,
    processingMs: 0,
  };
}

function traceInputSnapshot(event: EventReviewRow): Record<string, unknown> {
  return {
    title: event.title,
    start_datetime: event.start_datetime,
    source_name: event.source_name,
    source_url: event.source_url,
  };
}

function isReviewable(event: EventReviewRow): boolean {
  return event.status === "draft" &&
    (event.llm_review_status === REVIEWABLE_LLM_REVIEW_STATUS_PENDING ||
      event.llm_review_status === LLM_EVENT_REVIEW_STATUS.NOT_REQUIRED);
}

async function logReviewEvent(
  deps: ReviewQueueDeps,
  level: "log" | "warn" | "error",
  message: string,
  metadata: Record<string, unknown>,
): Promise<void> {
  if (deps.cronContext) {
    await logCronRunEvent(
      deps.supabase,
      deps.cronContext,
      level,
      message,
      metadata,
    );
    return;
  }

  logEdgeEvent(level, message, metadata);
}

async function handleMissingEvent(
  deps: ReviewQueueDeps,
  startedRow: EventLlmReviewQueueRow,
): Promise<EventReviewQueueRowResult> {
  await markQueueDead(
    deps.supabase,
    startedRow.id,
    "event missing before review",
  );
  await logReviewEvent(deps, "error", "event_review_dead_lettered", {
    function: "process-event-review-queue",
    queue_id: startedRow.id,
    event_id: startedRow.event_id,
    reason: "event_missing_before_review",
  });
  return {
    outcome: "dead",
    appliedDecision: null,
    failed: true,
  };
}

async function handleNonReviewableEvent(
  deps: ReviewQueueDeps,
  startedRow: EventLlmReviewQueueRow,
  event: EventReviewRow,
  reason =
    `Event no longer reviewable (status=${event.status}, llm_status=${event.llm_review_status}).`,
): Promise<EventReviewQueueRowResult> {
  const skipped = buildSkippedReview(reason);
  await insertTrace(deps.supabase, {
    queueRow: startedRow,
    eventId: event.id,
    review: skipped,
    modelDecision: null,
    inputSnapshot: traceInputSnapshot(event),
    status: "skipped",
  });
  await markQueueSucceeded(deps.supabase, startedRow.id);
  return {
    outcome: "skipped",
    appliedDecision: null,
    failed: false,
  };
}

function buildReviewInput(event: EventReviewRow) {
  return {
    eventId: event.id,
    title: event.title,
    description: event.description,
    startDatetime: event.start_datetime,
    endDatetime: event.end_datetime,
    timezone: event.timezone,
    venueName: event.venue_name,
    address: event.address,
    sourceName: event.source_name,
    sourceUrl: event.source_url,
    category: null,
    tags: [],
  };
}

async function logReviewSignals(
  deps: ReviewQueueDeps,
  startedRow: EventLlmReviewQueueRow,
  event: EventReviewRow,
  review: AppliedLlmEventReviewDecision,
): Promise<void> {
  if (review.status === LLM_EVENT_REVIEW_STATUS.FAILED) {
    await logReviewEvent(deps, "warn", "event_review_provider_failed", {
      function: "process-event-review-queue",
      queue_id: startedRow.id,
      event_id: event.id,
      error_code: review.errorCode,
      error_message: review.errorMessage,
    });
    if (
      review.errorCode === "malformed_json" ||
      review.errorCode === "schema_validation_error"
    ) {
      await logReviewEvent(deps, "warn", "event_review_malformed_response", {
        function: "process-event-review-queue",
        queue_id: startedRow.id,
        event_id: event.id,
        error_code: review.errorCode,
      });
    }
  }
  if (review.flags.includes("low_confidence")) {
    await logReviewEvent(deps, "warn", "event_review_low_confidence", {
      function: "process-event-review-queue",
      queue_id: startedRow.id,
      event_id: event.id,
      confidence: review.confidence,
      threshold: deps.config.confidenceThreshold,
    });
  }
}

async function fetchReviewMemory(
  deps: ReviewQueueDeps,
  eventId: string,
): Promise<ReviewMemoryContext | null> {
  try {
    const enabled = await isMemoryFeatureEnabled(deps.supabase, "review-memory");
    if (!enabled) return null;

    // Look up existing embedding for this event
    const { data: embRow, error: embErr } = await deps.supabase
      .from("event_embeddings")
      .select("embedding")
      .eq("event_id", eventId)
      .maybeSingle();

    if (embErr || !embRow) return null;

    // Parse the vector string back to number array
    const embStr = String((embRow as { embedding: string }).embedding);
    const embedding = JSON.parse(embStr) as number[];
    if (!Array.isArray(embedding) || embedding.length === 0) return null;

    // Fetch event's city_id for scoping
    const { data: evt } = await deps.supabase
      .from("events")
      .select("city_id")
      .eq("id", eventId)
      .maybeSingle();

    const cityId = (evt as { city_id: string | null } | null)?.city_id ?? null;

    const { contexts, confidenceAdjustment } = await fetchSimilarReviewContext(
      deps.supabase,
      embedding,
      eventId,
      cityId,
      5,
    );

    if (contexts.length === 0) return null;

    return {
      memoryPrompt: formatReviewMemoryPrompt(contexts),
      similarEventIds: contexts.map((c) => c.eventId),
      confidenceDelta: confidenceAdjustment.delta,
      confidenceReason: confidenceAdjustment.reason,
    };
  } catch {
    // Memory retrieval failure is non-fatal
    return null;
  }
}

async function reviewAndApplyEvent(
  deps: ReviewQueueDeps,
  startedRow: EventLlmReviewQueueRow,
  event: EventReviewRow,
): Promise<EventReviewQueueRowResult> {
  const memoryCtx = await fetchReviewMemory(deps, event.id);

  const review = await (deps.reviewEvent ?? reviewEventWithLlm)(
    buildReviewInput(event),
    {
      config: deps.config,
    },
    memoryCtx,
  );

  const applied = await applyEventDecision(
    deps.supabase,
    event,
    startedRow,
    review,
  );

  await logReviewSignals(deps, startedRow, event, review);

  if (!applied) {
    return await handleNonReviewableEvent(
      deps,
      startedRow,
      event,
      "Event status changed while applying review decision.",
    );
  }

  await logReviewEvent(deps, "log", "event_review_applied", {
    function: "process-event-review-queue",
    queue_id: startedRow.id,
    event_id: event.id,
    applied_decision: review.appliedDecision,
    model_decision: review.modelDecision,
    status: review.status,
    confidence: review.confidence,
  });

  return {
    outcome: "succeeded",
    appliedDecision: review.appliedDecision,
    failed: review.status === LLM_EVENT_REVIEW_STATUS.FAILED,
  };
}

export async function processReviewQueueRow(
  deps: ReviewQueueDeps,
  row: EventLlmReviewQueueRow,
): Promise<EventReviewQueueRowResult> {
  const startedRow = await markRowStarted(deps.supabase, row.id);
  await logReviewEvent(deps, "log", "event_review_started", {
    function: "process-event-review-queue",
    queue_id: startedRow.id,
    event_id: startedRow.event_id,
    attempt_count: startedRow.attempt_count,
    max_attempts: startedRow.max_attempts,
  });

  try {
    const event = await loadEvent(deps.supabase, startedRow.event_id);
    if (!event) {
      return await handleMissingEvent(deps, startedRow);
    }

    if (!isReviewable(event)) {
      return await handleNonReviewableEvent(deps, startedRow, event);
    }

    return await reviewAndApplyEvent(deps, startedRow, event);
  } catch (error) {
    const message = errorMessage(error);
    if (startedRow.attempt_count >= startedRow.max_attempts) {
      await markQueueDead(deps.supabase, startedRow.id, message);
      await logReviewEvent(deps, "error", "event_review_dead_lettered", {
        function: "process-event-review-queue",
        queue_id: startedRow.id,
        event_id: startedRow.event_id,
        reason: message,
      });
      return {
        outcome: "dead",
        appliedDecision: null,
        failed: true,
      };
    }

    await markQueueRetrying(
      deps.supabase,
      startedRow,
      message,
      deps.config.retryBaseMs,
    );
    return {
      outcome: "retrying",
      appliedDecision: null,
      failed: true,
    };
  }
}

export async function processReviewQueueBatch(
  deps: ReviewQueueDeps,
): Promise<ReviewQueueBatchResult> {
  const startedAt = deps.now?.() ?? Date.now();
  const summary: ReviewQueueBatchResult = {
    claimed: 0,
    reaped: 0,
    succeeded: 0,
    failed: 0,
    retrying: 0,
    dead: 0,
    approved: 0,
    rejected: 0,
    needsAdminReview: 0,
  };

  summary.reaped = await reapStuckRows(deps.supabase);

  const claimed = await claimRows(deps.supabase, resolveBatchSize());
  summary.claimed = claimed.length;
  await logReviewEvent(deps, "log", "event_review_queue_claimed", {
    function: "process-event-review-queue",
    claimed: summary.claimed,
    reaped: summary.reaped,
  });

  for (let index = 0; index < claimed.length; index += 1) {
    const elapsed = (deps.now?.() ?? Date.now()) - startedAt;
    if (shouldStopBeforeStartingNextRow(elapsed)) {
      await releaseUnstartedRows(deps.supabase, claimed.slice(index));
      break;
    }

    const row = claimed[index];
    if (!row) continue;

    const result = await processReviewQueueRow(deps, row);
    if (result.outcome === "succeeded" || result.outcome === "skipped") {
      summary.succeeded += 1;
      if (result.appliedDecision === LLM_EVENT_REVIEW_DECISION.APPROVE) {
        summary.approved += 1;
      }
      if (result.appliedDecision === LLM_EVENT_REVIEW_DECISION.REJECT) {
        summary.rejected += 1;
      }
      if (
        result.appliedDecision === LLM_EVENT_REVIEW_DECISION.NEEDS_ADMIN_REVIEW
      ) {
        summary.needsAdminReview += 1;
      }
      if (result.failed) summary.failed += 1;
      continue;
    }

    if (result.outcome === "retrying") {
      summary.retrying += 1;
      summary.failed += 1;
      continue;
    }

    summary.dead += 1;
    summary.failed += 1;
  }

  await logReviewEvent(deps, "log", "event review queue batch done", {
    function: "process-event-review-queue",
    ...summary,
  });

  return summary;
}

async function loadEventReviewFeatureConfig(
  supabase: SupabaseClient,
): Promise<
  { model: string; enabled: boolean; provider: string | null } | null
> {
  try {
    const { data, error } = await supabase
      .from("ai_feature_config")
      .select("model_id, enabled, approved_ai_models(provider)")
      .eq("feature", "event-review")
      .maybeSingle();
    if (error || !data) return null;
    const row = data as unknown as {
      model_id: string;
      enabled: boolean;
      approved_ai_models: { provider: string } | null;
    };
    return {
      model: row.model_id,
      enabled: row.enabled,
      provider: row.approved_ai_models?.provider ?? null,
    };
  } catch {
    return null;
  }
}

export async function buildReviewQueueDeps(
  supabase: SupabaseClient,
): Promise<ReviewQueueDeps> {
  const dbOverrides = await loadEventReviewFeatureConfig(supabase);
  return {
    supabase,
    config: resolveLlmReviewConfig(Deno.env, dbOverrides),
  };
}
