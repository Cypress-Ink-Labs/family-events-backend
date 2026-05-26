import { type SupabaseClient } from "@supabase/supabase-js";
import { errorMessage, logEdgeEvent } from "../../_shared/logger.ts";
import { parsers } from "../../scrape-source/parsers/index.ts";
import {
  buildParserContext,
  importParsedSourceEvents,
} from "../../scrape-source/lib/process-source.ts";
import {
  validateParsedEvents,
} from "../../scrape-source/lib/extraction-pipeline.ts";
import type {
  EventSourceRow,
  ExtractionMode,
  FetchedArtifact,
  ParsedEvent,
  SourceType,
} from "../../scrape-source/lib/types.ts";
import type { SourceParser } from "../../scrape-source/parsers/index.ts";
import { extractWithLlm, type LlmConfig } from "./llm-extraction.ts";

export interface SourceQueueRow {
  id: number;
  source_id: string | null;
  source_run_id: string | null;
  attempt_count: number;
}

export interface ProcessSourceQueueResult {
  outcome: "succeeded" | "retry" | "skipped";
  imported: number;
}

interface SourceQueueWorkerDependencies {
  parsers: Record<SourceType, SourceParser>;
  importParsedSourceEvents: typeof importParsedSourceEvents;
  extractWithLlm: typeof extractWithLlm;
}

export function shouldReleaseBeforeSourceStart(
  elapsedMs: number,
  budgetMs = 105_000,
): boolean {
  return elapsedMs >= budgetMs;
}

export function sourceRetryDelayMinutes(
  attemptCount: number,
): 5 | 15 | 60 | null {
  if (attemptCount >= 4) return null;
  if (attemptCount === 1) return 5;
  if (attemptCount === 2) return 15;
  return 60;
}

export function buildSourceRunInsert(
  sourceId: string,
): { source_id: string; status: "running" } {
  return { source_id: sourceId, status: "running" };
}

export function shouldFallbackToLlm(
  extractionMode: ExtractionMode,
  deterministicValidCount: number,
  deterministicError: unknown,
): boolean {
  return (
    extractionMode === "deterministic_then_llm" &&
    (deterministicValidCount === 0 || deterministicError != null)
  );
}

export function buildExtractionErrorTrace(input: {
  queueId: number;
  runId: string;
  sourceId: string;
  extractionMode: ExtractionMode;
  extractor: "deterministic" | "llm";
  error: string;
}) {
  return {
    source_queue_id: input.queueId,
    source_run_id: input.runId,
    source_id: input.sourceId,
    extraction_mode: input.extractionMode,
    extractor: input.extractor,
    status: "error" as const,
    error: input.error,
    parsed_event_count: 0,
  };
}

export function planSourceQueueClaimHandling(
  claimedIds: number[],
  elapsedMs: number,
): { start: number | null; release: number[] } {
  if (claimedIds.length === 0) return { start: null, release: [] };
  if (shouldReleaseBeforeSourceStart(elapsedMs)) {
    return { start: null, release: claimedIds };
  }
  const [first, ...rest] = claimedIds;
  return { start: first, release: rest };
}

export async function reapStuckSourceQueueRows(
  supabase: SupabaseClient,
): Promise<number> {
  const { data, error } = await supabase.rpc(
    "reap_stuck_source_scrape_queue_rows",
  );
  if (error) throw error;
  return Number(data ?? 0);
}

export async function markSkipped(
  supabase: SupabaseClient,
  queueId: number,
  reason: string,
): Promise<void> {
  const { error } = await supabase.rpc("mark_source_scrape_queue_skipped", {
    p_queue_id: queueId,
    p_skip_reason: reason,
  });
  if (error) throw error;
}

export async function markStarted(supabase: SupabaseClient, queueId: number) {
  const { data, error } = await supabase.rpc(
    "mark_source_scrape_queue_started",
    {
      p_queue_id: queueId,
    },
  );
  if (error) throw error;
  return data as SourceQueueRow;
}

export async function scheduleRetry(
  supabase: SupabaseClient,
  queueId: number,
  attemptCount: number,
  errorMessage: string,
): Promise<void> {
  const { error } = await supabase.rpc("source_scrape_queue_schedule_retry", {
    p_queue_id: queueId,
    p_attempt_count: attemptCount,
    p_error: errorMessage,
  });
  if (error) throw error;
}

export async function createAndLinkSourceRun(
  supabase: SupabaseClient,
  queueId: number,
  sourceId: string,
): Promise<string> {
  const { data: run, error: runError } = await supabase
    .from("source_runs")
    .insert(buildSourceRunInsert(sourceId))
    .select("id")
    .single();
  if (runError) throw runError;

  const runId = String((run as { id: string }).id);
  const { error: linkError } = await supabase
    .from("source_scrape_queue")
    .update({ source_run_id: runId })
    .eq("id", queueId);
  if (linkError) throw linkError;

  return runId;
}

export async function persistExtractionTrace(
  supabase: SupabaseClient,
  input: Record<string, unknown>,
): Promise<void> {
  const { error } = await supabase.from("source_extraction_traces").insert(
    input,
  );
  if (error) throw error;
}

async function markRunError(
  supabase: SupabaseClient,
  runId: string,
  errorMessage: string,
): Promise<void> {
  await supabase
    .from("source_runs")
    .update({
      completed_at: new Date().toISOString(),
      status: "error",
      error_log: errorMessage.slice(0, 1000),
    })
    .eq("id", runId);
}

const defaultWorkerDependencies: SourceQueueWorkerDependencies = {
  parsers,
  importParsedSourceEvents,
  extractWithLlm,
};

async function handleExtractionFailure(
  supabase: SupabaseClient,
  row: SourceQueueRow,
  runId: string,
  source: EventSourceRow,
  startedRow: SourceQueueRow,
  extractor: "deterministic" | "llm",
  err: unknown,
): Promise<ProcessSourceQueueResult> {
  const message = errorMessage(err);
  await persistExtractionTrace(
    supabase,
    buildExtractionErrorTrace({
      queueId: row.id,
      runId,
      sourceId: source.id,
      extractionMode: source.extraction_mode,
      extractor,
      error: message,
    }),
  );
  await markRunError(supabase, runId, message);
  await scheduleRetry(supabase, row.id, startedRow.attempt_count, message);
  return { outcome: "retry", imported: 0 };
}

type RunnableSourceRun =
  | {
    status: "loaded";
    source: EventSourceRow;
    startedRow: SourceQueueRow;
    runId: string;
  }
  | { status: "skipped"; result: ProcessSourceQueueResult };

type SourceExtractionResult =
  | { status: "extracted"; parsedEvents: ParsedEvent[] }
  | { status: "retry"; result: ProcessSourceQueueResult };

interface DeterministicExtractionPhase {
  events: ParsedEvent[];
  error: unknown;
  shouldUseLlm: boolean;
  fallbackReason: string | null;
}

async function loadRunnableSourceAndRun(
  supabase: SupabaseClient,
  row: SourceQueueRow,
): Promise<RunnableSourceRun> {
  if (!row.source_id) {
    await markSkipped(supabase, row.id, "source missing from queue row");
    return { status: "skipped", result: { outcome: "skipped", imported: 0 } };
  }

  const { data: sourceRaw, error: sourceError } = await supabase
    .from("event_sources")
    .select("*")
    .eq("id", row.source_id)
    .maybeSingle();
  if (sourceError) throw sourceError;

  const source = sourceRaw as EventSourceRow | null;
  if (!source) {
    await markSkipped(supabase, row.id, "source deleted before processing");
    return { status: "skipped", result: { outcome: "skipped", imported: 0 } };
  }
  if (!source.is_active) {
    await markSkipped(supabase, row.id, "source disabled before processing");
    return { status: "skipped", result: { outcome: "skipped", imported: 0 } };
  }

  const startedRow = await markStarted(supabase, row.id);
  const runId = await createAndLinkSourceRun(supabase, row.id, source.id);
  return { status: "loaded", source, startedRow, runId };
}

async function runDeterministicExtractionPhase(
  supabase: SupabaseClient,
  row: SourceQueueRow,
  source: EventSourceRow,
  runId: string,
  parser: SourceParser,
  artifact: FetchedArtifact,
  ctx: ReturnType<typeof buildParserContext>,
): Promise<DeterministicExtractionPhase> {
  if (source.extraction_mode === "llm") {
    return {
      events: [],
      error: null,
      shouldUseLlm: true,
      fallbackReason: null,
    };
  }

  try {
    const events = validateParsedEvents(
      await parser.extractEvents(source, artifact, ctx),
    );
    const fallbackReason = events.length === 0
      ? "deterministic extractor returned no events"
      : null;
    await persistExtractionTrace(supabase, {
      source_queue_id: row.id,
      source_run_id: runId,
      source_id: source.id,
      extraction_mode: source.extraction_mode,
      extractor: "deterministic",
      status: events.length > 0 ? "success" : "fallback",
      input_bytes: artifact.body.length,
      parsed_event_count: events.length,
      fallback_reason: fallbackReason,
    });
    return {
      events,
      error: null,
      shouldUseLlm: shouldFallbackToLlm(
        source.extraction_mode,
        events.length,
        null,
      ),
      fallbackReason,
    };
  } catch (err) {
    const message = errorMessage(err);
    await persistExtractionTrace(
      supabase,
      buildExtractionErrorTrace({
        queueId: row.id,
        runId,
        sourceId: source.id,
        extractionMode: source.extraction_mode,
        extractor: "deterministic",
        error: message,
      }),
    );
    return {
      events: [],
      error: err,
      shouldUseLlm: shouldFallbackToLlm(source.extraction_mode, 0, err),
      fallbackReason: message,
    };
  }
}

async function extractParsedEventsForSource(
  supabase: SupabaseClient,
  row: SourceQueueRow,
  source: EventSourceRow,
  startedRow: SourceQueueRow,
  runId: string,
  dependencies: SourceQueueWorkerDependencies,
): Promise<SourceExtractionResult> {
  const parser = dependencies.parsers[source.source_type];
  if (!parser) {
    const result = await handleExtractionFailure(
      supabase,
      row,
      runId,
      source,
      startedRow,
      "deterministic",
      new Error(`No parser registered for source_type=${source.source_type}`),
    );
    return { status: "retry", result };
  }

  const ctx = buildParserContext(
    source.city_id
      ? await resolveTimezone(supabase, source)
      : "America/Chicago",
  );
  let artifact: FetchedArtifact;
  try {
    artifact = await parser.fetchArtifact(source, ctx);
  } catch (err) {
    const result = await handleExtractionFailure(
      supabase,
      row,
      runId,
      source,
      startedRow,
      "deterministic",
      err,
    );
    return { status: "retry", result };
  }

  const deterministic = await runDeterministicExtractionPhase(
    supabase,
    row,
    source,
    runId,
    parser,
    artifact,
    ctx,
  );

  if (
    source.extraction_mode === "deterministic" &&
    (deterministic.error || deterministic.events.length === 0)
  ) {
    const message = deterministic.error instanceof Error
      ? deterministic.error.message
      : "Deterministic extraction returned no valid events";
    await markRunError(supabase, runId, message);
    await scheduleRetry(supabase, row.id, startedRow.attempt_count, message);
    return {
      status: "retry",
      result: { outcome: "retry", imported: 0 },
    };
  }

  if (source.extraction_mode !== "llm" && deterministic.shouldUseLlm) {
    logEdgeEvent("warn", "deterministic extraction falling back to llm", {
      function: "process-source-queue",
      source_id: source.id,
      queue_row_id: row.id,
      deterministic_error: deterministic.error instanceof Error
        ? deterministic.error.message
        : null,
    });
  }

  let parsedEvents = deterministic.events;
  if (deterministic.shouldUseLlm) {
    try {
      const llm = await dependencies.extractWithLlm(source, artifact);
      const valid = validateParsedEvents(llm.events);
      if (valid.length !== llm.events.length) {
        throw new Error("LLM returned invalid ParsedEvent rows");
      }
      await persistExtractionTrace(supabase, {
        source_queue_id: row.id,
        source_run_id: runId,
        source_id: source.id,
        extraction_mode: source.extraction_mode,
        extractor: "llm",
        provider: llm.config.provider,
        model: llm.config.model,
        status: "success",
        input_bytes: artifact.body.length,
        parsed_event_count: valid.length,
        fallback_reason: deterministic.fallbackReason,
        latency_ms: llm.latencyMs,
        reasoning_summary: `LLM extraction completed in ${llm.latencyMs}ms`,
      });
      parsedEvents = valid;
    } catch (err) {
      const result = await handleExtractionFailure(
        supabase,
        row,
        runId,
        source,
        startedRow,
        "llm",
        err,
      );
      return { status: "retry", result };
    }
  }

  return { status: "extracted", parsedEvents };
}

export async function processSourceQueueRow(
  supabase: SupabaseClient,
  row: SourceQueueRow,
  dependencies: SourceQueueWorkerDependencies = defaultWorkerDependencies,
): Promise<ProcessSourceQueueResult> {
  const runnable = await loadRunnableSourceAndRun(supabase, row);
  if (runnable.status === "skipped") {
    return runnable.result;
  }

  const extraction = await extractParsedEventsForSource(
    supabase,
    row,
    runnable.source,
    runnable.startedRow,
    runnable.runId,
    dependencies,
  );
  if (extraction.status === "retry") {
    return extraction.result;
  }

  const result = await dependencies.importParsedSourceEvents(
    supabase,
    runnable.source,
    runnable.runId,
    extraction.parsedEvents,
  );

  if (result.status !== "success" && result.status !== "partial") {
    await scheduleRetry(
      supabase,
      row.id,
      runnable.startedRow.attempt_count,
      result.error ?? "Source processing failed",
    );
    return { outcome: "retry", imported: result.eventsImported };
  }

  const { error: successUpdateError } = await supabase
    .from("source_scrape_queue")
    .update({
      status: "succeeded",
      finished_at: new Date().toISOString(),
      last_error: null,
    })
    .eq("id", row.id);
  if (successUpdateError) throw successUpdateError;

  return { outcome: "succeeded", imported: result.eventsImported };
}

async function resolveTimezone(
  supabase: SupabaseClient,
  source: EventSourceRow,
): Promise<string> {
  if (!source.city_id) return "America/Chicago";
  const { data } = await supabase
    .from("cities")
    .select("timezone")
    .eq("id", source.city_id)
    .maybeSingle();
  const timezone = (data as { timezone?: unknown } | null)?.timezone;
  return typeof timezone === "string" && timezone
    ? timezone
    : "America/Chicago";
}
