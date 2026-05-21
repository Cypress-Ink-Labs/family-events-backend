import { type SupabaseClient } from "@supabase/supabase-js";
import { logEdgeEvent } from "../../_shared/logger.ts";
import { parsers } from "../../scrape-source/parsers/index.ts";
import {
  buildParserContext,
  processSource,
} from "../../scrape-source/lib/process-source.ts";
import {
  normalizeArtifactForLlm,
  parseLlmParsedEvents,
  validateParsedEvents,
} from "../../scrape-source/lib/extraction-pipeline.ts";
import type {
  EventSourceRow,
  ExtractionMode,
  FetchedArtifact,
  ParsedEvent,
} from "../../scrape-source/lib/types.ts";

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

interface LlmConfig {
  provider: string;
  model: string;
  baseUrl: string;
  apiKey: string;
  configured: boolean;
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

function resolveLlmConfig(): LlmConfig {
  const provider = Deno.env.get("AI_PROVIDER") ?? "openai";
  const baseUrl = (Deno.env.get("AI_BASE_URL") ??
    (provider === "openai" ? "https://api.openai.com/v1" : "")).replace(
      /\/+$/,
      "",
    );
  const model = Deno.env.get("AI_MODEL") ?? Deno.env.get("OPENAI_MODEL") ??
    (provider === "openai" ? "gpt-4o-mini" : "qwen3:1.7b");
  const apiKey = Deno.env.get("AI_API_KEY") ?? Deno.env.get("OPENAI_API_KEY") ??
    (provider === "ollama" ? "ollama" : "");
  return {
    provider,
    baseUrl,
    model,
    apiKey,
    configured: Boolean(baseUrl && (apiKey || provider === "ollama")),
  };
}

async function extractWithLlm(
  source: EventSourceRow,
  artifact: FetchedArtifact,
): Promise<{ events: ParsedEvent[]; config: LlmConfig; latencyMs: number }> {
  const config = resolveLlmConfig();
  if (!config.configured) {
    throw new Error("LLM extraction provider is not configured");
  }

  const startedAt = Date.now();
  const response = await fetch(`${config.baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: config.model,
      temperature: 0.1,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content:
            'Extract family events from fetched source content. Respond with JSON only: {"events":[{"title":string,"description":string,"startDatetime":string,"endDatetime":string|null,"venueName":string|null,"address":string|null,"sourceUrl":string|null,"imageUrl":string|null,"images":string[],"price":number|null,"isFree":boolean}]}',
        },
        {
          role: "user",
          content: JSON.stringify({
            source_name: source.name,
            source_url: source.url,
            content_type: artifact.contentType,
            content: normalizeArtifactForLlm(artifact),
          }),
        },
      ],
    }),
    signal: AbortSignal.timeout(45_000),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(
      `LLM extraction failed (${response.status}): ${body.slice(0, 200)}`,
    );
  }

  const payload = await response.json();
  const content = payload?.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    throw new Error("LLM extraction returned an empty response");
  }

  return {
    events: parseLlmParsedEvents(content),
    config,
    latencyMs: Date.now() - startedAt,
  };
}

async function handleExtractionFailure(
  supabase: SupabaseClient,
  row: SourceQueueRow,
  runId: string,
  source: EventSourceRow,
  startedRow: SourceQueueRow,
  extractor: "deterministic" | "llm",
  err: unknown,
): Promise<ProcessSourceQueueResult> {
  const message = err instanceof Error ? err.message : String(err);
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

export async function processQueueRow(
  supabase: SupabaseClient,
  row: SourceQueueRow,
): Promise<ProcessSourceQueueResult> {
  if (!row.source_id) {
    await markSkipped(supabase, row.id, "source missing from queue row");
    return { outcome: "skipped", imported: 0 };
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
    return { outcome: "skipped", imported: 0 };
  }
  if (!source.is_active) {
    await markSkipped(supabase, row.id, "source disabled before processing");
    return { outcome: "skipped", imported: 0 };
  }

  const startedRow = await markStarted(supabase, row.id);
  const runId = await createAndLinkSourceRun(supabase, row.id, source.id);
  const parser = parsers[source.source_type];
  if (!parser) {
    return handleExtractionFailure(
      supabase,
      row,
      runId,
      source,
      startedRow,
      "deterministic",
      new Error(`No parser registered for source_type=${source.source_type}`),
    );
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
    return handleExtractionFailure(
      supabase,
      row,
      runId,
      source,
      startedRow,
      "deterministic",
      err,
    );
  }

  let parsedEvents: ParsedEvent[] = [];
  let deterministicError: unknown = null;
  let fallbackReason: string | null = null;

  if (source.extraction_mode !== "llm") {
    try {
      const deterministicEvents = validateParsedEvents(
        await parser.extractEvents(source, artifact, ctx),
      );
      await persistExtractionTrace(supabase, {
        source_queue_id: row.id,
        source_run_id: runId,
        source_id: source.id,
        extraction_mode: source.extraction_mode,
        extractor: "deterministic",
        status: deterministicEvents.length > 0 ? "success" : "fallback",
        input_bytes: artifact.body.length,
        parsed_event_count: deterministicEvents.length,
        fallback_reason: deterministicEvents.length === 0
          ? "deterministic extractor returned no events"
          : null,
      });
      parsedEvents = deterministicEvents;
    } catch (err) {
      deterministicError = err;
      await persistExtractionTrace(
        supabase,
        buildExtractionErrorTrace({
          queueId: row.id,
          runId,
          sourceId: source.id,
          extractionMode: source.extraction_mode,
          extractor: "deterministic",
          error: err instanceof Error ? err.message : String(err),
        }),
      );
    }
  }

  if (
    source.extraction_mode === "deterministic" &&
    (deterministicError || parsedEvents.length === 0)
  ) {
    const message = deterministicError instanceof Error
      ? deterministicError.message
      : "Deterministic extraction returned no valid events";
    await markRunError(supabase, runId, message);
    await scheduleRetry(supabase, row.id, startedRow.attempt_count, message);
    return { outcome: "retry", imported: 0 };
  }

  if (
    shouldFallbackToLlm(
      source.extraction_mode,
      parsedEvents.length,
      deterministicError,
    )
  ) {
    fallbackReason = deterministicError instanceof Error
      ? deterministicError.message
      : "deterministic extractor returned no events";
    logEdgeEvent("warn", "deterministic extraction falling back to llm", {
      function: "process-source-queue",
      source_id: source.id,
      queue_row_id: row.id,
      deterministic_error: deterministicError instanceof Error
        ? deterministicError.message
        : null,
    });
  }

  if (
    source.extraction_mode === "llm" ||
    shouldFallbackToLlm(
      source.extraction_mode,
      parsedEvents.length,
      deterministicError,
    )
  ) {
    try {
      const llm = await extractWithLlm(source, artifact);
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
        fallback_reason: fallbackReason,
        latency_ms: llm.latencyMs,
        reasoning_summary: `LLM extraction completed in ${llm.latencyMs}ms`,
      });
      parsedEvents = valid;
    } catch (err) {
      return handleExtractionFailure(
        supabase,
        row,
        runId,
        source,
        startedRow,
        "llm",
        err,
      );
    }
  }

  const result = await processSource(supabase, source, runId, parsedEvents);
  await supabase
    .from("source_scrape_queue")
    .update({
      status: "succeeded",
      finished_at: new Date().toISOString(),
      last_error: null,
    })
    .eq("id", row.id);
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
