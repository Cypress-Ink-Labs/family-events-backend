import type { SupabaseClient } from "@supabase/supabase-js";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, logEdgeEvent } from "../_shared/logger.ts";

// ── Constants ────────────────────────────────────────────────────────────────

const EMBEDDING_MODEL = "text-embedding-3-small";
const EMBEDDING_DIMENSIONS = 1536;
const OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings";
const TIMEOUT_MS = 30_000;

/**
 * Cap combined text length to ~2000 chars before sending to the embeddings API.
 * text-embedding-3-small supports 8191 tokens, but shorter text is cheaper and
 * still captures the semantic essence for similarity matching.
 */
const MAX_INPUT_CHARS = 2000;

// ── Types ────────────────────────────────────────────────────────────────────

export interface EmbedEventInput {
  event_id: string;
  title: string;
  description?: string | null;
}

export interface EmbedEventResult {
  event_id: string;
  model: string;
  dimensions: number;
  processing_ms: number;
  stored: boolean;
}

interface OpenAiEmbeddingResponse {
  data: Array<{ embedding: number[]; index: number }>;
  model: string;
  usage: { prompt_tokens: number; total_tokens: number };
}

export interface EmbedEventDeps {
  supabase: SupabaseClient;
  openAiApiKey: string;
  fetchImpl?: typeof fetch;
}

// ── Core logic ───────────────────────────────────────────────────────────────

function buildEmbeddingInput(
  title: string,
  description?: string | null,
): string {
  const parts = [title.trim()];
  if (description) {
    parts.push(description.trim());
  }
  const combined = parts.join("\n\n");
  return combined.slice(0, MAX_INPUT_CHARS);
}

export async function generateEmbedding(
  text: string,
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<
  { embedding: number[]; usage: { promptTokens: number; totalTokens: number } }
> {
  const response = await fetchImpl(OPENAI_EMBEDDINGS_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: EMBEDDING_MODEL,
      input: text,
      dimensions: EMBEDDING_DIMENSIONS,
    }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });

  if (!response.ok) {
    const errorBody = await response.text().catch(() => "");
    throw new EmbedEventUpstreamError(
      `OpenAI embeddings failed (${response.status}): ${
        errorBody.slice(0, 200)
      }`,
    );
  }

  const result = (await response.json()) as OpenAiEmbeddingResponse;
  const vector = result.data?.[0]?.embedding;

  if (!Array.isArray(vector) || vector.length !== EMBEDDING_DIMENSIONS) {
    throw new Error(
      `OpenAI returned unexpected embedding dimensions: ${
        vector?.length ?? "null"
      }`,
    );
  }

  return {
    embedding: vector,
    usage: {
      promptTokens: result.usage?.prompt_tokens ?? 0,
      totalTokens: result.usage?.total_tokens ?? 0,
    },
  };
}

export async function storeEmbedding(
  supabase: SupabaseClient,
  eventId: string,
  embedding: number[],
  model: string,
): Promise<boolean> {
  // Upsert: if re-embedding (model change, re-classification), replace.
  const vectorStr = `[${embedding.join(",")}]`;
  const { error } = await supabase
    .from("event_embeddings")
    .upsert(
      {
        event_id: eventId,
        embedding: vectorStr,
        model,
        created_at: new Date().toISOString(),
      },
      { onConflict: "event_id" },
    );

  if (error) throw error;
  return true;
}

export async function embedEvent(
  input: EmbedEventInput,
  deps: EmbedEventDeps,
): Promise<EmbedEventResult> {
  const startedAt = Date.now();
  const text = buildEmbeddingInput(input.title, input.description);

  const { embedding, usage } = await generateEmbedding(
    text,
    deps.openAiApiKey,
    deps.fetchImpl,
  );

  const stored = await storeEmbedding(
    deps.supabase,
    input.event_id,
    embedding,
    EMBEDDING_MODEL,
  );

  const processingMs = Date.now() - startedAt;

  logEdgeEvent("log", "embed-event completed", {
    function: "embed-event",
    event_id: input.event_id,
    model: EMBEDDING_MODEL,
    dimensions: EMBEDDING_DIMENSIONS,
    input_chars: text.length,
    prompt_tokens: usage.promptTokens,
    total_tokens: usage.totalTokens,
    processing_ms: processingMs,
  });

  return {
    event_id: input.event_id,
    model: EMBEDDING_MODEL,
    dimensions: EMBEDDING_DIMENSIONS,
    processing_ms: processingMs,
    stored,
  };
}

// ── Request handler (for edge function serving) ─────────────────────────────

export async function handleEmbedEventRequest(
  body: unknown,
  deps: EmbedEventDeps,
): Promise<EmbedEventResult> {
  const payload =
    body !== null && typeof body === "object" && !Array.isArray(body)
      ? (body as Record<string, unknown>)
      : {};

  const eventId = typeof payload.event_id === "string"
    ? payload.event_id
    : null;
  const title = typeof payload.title === "string" ? payload.title.trim() : "";
  const description = typeof payload.description === "string"
    ? payload.description
    : null;

  if (!eventId) {
    throw new EmbedEventRequestError("event_id is required", 400);
  }

  if (!title) {
    // If only event_id is provided, fetch title+description from DB
    const { data: event, error } = await deps.supabase
      .from("events")
      .select("title, description")
      .eq("id", eventId)
      .maybeSingle();

    if (error) throw error;
    if (!event || !event.title) {
      throw new EmbedEventRequestError("event not found or has no title", 404);
    }

    return embedEvent(
      { event_id: eventId, title: event.title, description: event.description },
      deps,
    );
  }

  return embedEvent({ event_id: eventId, title, description }, deps);
}

export class EmbedEventRequestError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

export class EmbedEventUpstreamError extends Error {
  readonly status = 502;

  constructor(message: string) {
    super(message);
  }
}

// ── Standalone handler for Deno.serve ───────────────────────────────────────

import { createClient } from "@supabase/supabase-js";
import { requireServiceRole } from "../_shared/auth.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const openAiApiKey = Deno.env.get("OPENAI_API_KEY") ?? "";

  const auth = requireServiceRole(req, serviceRoleKey);
  if (!auth.ok) {
    return jsonResponse({ error: auth.message }, auth.status);
  }

  if (!openAiApiKey) {
    return jsonResponse({ error: "OPENAI_API_KEY not configured" }, 500);
  }

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(
      { error: "Supabase service configuration missing" },
      500,
    );
  }

  try {
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const body = await req.json();
    const result = await handleEmbedEventRequest(body, {
      supabase,
      openAiApiKey,
    });
    return jsonResponse(result);
  } catch (err) {
    if (err instanceof EmbedEventRequestError) {
      return jsonResponse({ error: err.message }, err.status);
    }

    if (err instanceof EmbedEventUpstreamError) {
      await captureEdgeException(
        err,
        errorContext(err, { function: "embed-event", upstream: "openai" }),
      );
      logEdgeEvent(
        "warn",
        "embed-event upstream failed",
        errorContext(err, {
          function: "embed-event",
          upstream: "openai",
        }),
      );
      return jsonResponse({ error: err.message }, err.status);
    }

    await captureEdgeException(
      err,
      errorContext(err, { function: "embed-event" }),
    );
    logEdgeEvent(
      "error",
      "embed-event handler failed",
      errorContext(err, {
        function: "embed-event",
      }),
    );

    return jsonResponse(
      {
        error: "Internal error",
        executionId: Deno.env.get("SB_EXECUTION_ID") ?? null,
      },
      500,
    );
  }
}
