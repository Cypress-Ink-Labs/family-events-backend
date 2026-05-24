import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { requireServiceRole } from "../_shared/auth.ts";
import { captureEdgeException } from "../_shared/sentry.ts";
import { errorContext, errorMessage, logEdgeEvent } from "../_shared/logger.ts";
import {
  ALLOWED_PARENT_TIP_CATEGORIES,
  buildSystemPrompt,
  buildUserPrompt,
  LLM_PARENT_TIPS_PROMPT_VERSION,
  PARENT_TIPS_JSON_SCHEMA,
  type ParentTipCategory,
  type ParentTipsEventContext,
} from "./prompt.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

const AI_TIMEOUT_MS = 30_000;

const ALLOWED_OPENAI_MODELS = new Set([
  "gpt-4o-mini",
  "gpt-4o",
  "gpt-4-turbo",
  "gpt-4.1-nano",
  "gpt-4.1-mini",
  "gpt-4.1",
  "gpt-5-mini",
  "gpt-5",
]);
const DEFAULT_OPENAI_MODEL = "gpt-4.1-nano";
const DEFAULT_AI_BASE_URL = "https://api.openai.com/v1";
const DEFAULT_OLLAMA_API_KEY = "ollama";
const DEFAULT_OLLAMA_MODEL = "qwen3:1.7b";
const SUPPORTED_AI_PROVIDERS = new Set(["openai", "ollama", "localai"]);

type LlmProvider = "openai" | "ollama" | "localai";

interface LlmConfig {
  provider: LlmProvider;
  baseUrl: string;
  apiKey: string;
  model: string;
  configured: boolean;
  featureEnabled: boolean;
}

interface ParentTipRecord {
  category: string;
  text: string;
}

class GenerateParentTipsRequestError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function resolveProvider(value: string | undefined): LlmProvider {
  if (value && SUPPORTED_AI_PROVIDERS.has(value)) {
    return value as LlmProvider;
  }
  return "openai";
}

function normalizeBaseUrl(value: string): string {
  return value.replace(/\/+$/, "");
}

async function loadParentTipsFeatureConfig(
  supabase: SupabaseClient,
): Promise<{ modelId: string; provider: string; enabled: boolean } | null> {
  try {
    const { data, error } = await supabase
      .from("ai_feature_config")
      .select("model_id, enabled, approved_ai_models(provider)")
      .eq("feature", "parent-tips")
      .maybeSingle();
    if (error || !data) return null;
    const row = data as unknown as {
      model_id: string;
      enabled: boolean;
      approved_ai_models: { provider: string } | null;
    };
    return {
      modelId: row.model_id,
      provider: row.approved_ai_models?.provider ?? "openai",
      enabled: row.enabled,
    };
  } catch {
    return null;
  }
}

function resolveAiConfig(
  dbConfig: { modelId: string; provider: string; enabled: boolean } | null,
): LlmConfig {
  if (!dbConfig) {
    return {
      provider: "openai",
      baseUrl: "",
      apiKey: "",
      model: DEFAULT_OPENAI_MODEL,
      configured: false,
      featureEnabled: false,
    };
  }
  const provider = resolveProvider(dbConfig.provider);

  const rawBaseUrl = Deno.env.get("AI_BASE_URL") ??
    (provider === "openai" ? DEFAULT_AI_BASE_URL : "");
  const baseUrl = normalizeBaseUrl(rawBaseUrl);

  const rawModel = dbConfig.modelId ??
    Deno.env.get("AI_MODEL") ??
    Deno.env.get("OPENAI_MODEL");
  const model = provider === "openai"
    ? (ALLOWED_OPENAI_MODELS.has(rawModel) ? rawModel : DEFAULT_OPENAI_MODEL)
    : (rawModel ?? DEFAULT_OLLAMA_MODEL);

  const apiKey = Deno.env.get("AI_API_KEY") ??
    Deno.env.get("OPENAI_API_KEY") ??
    (provider === "localai" ? Deno.env.get("LOCALAI_API_KEY") : undefined) ??
    (provider === "ollama" ? DEFAULT_OLLAMA_API_KEY : "");

  return {
    provider,
    baseUrl,
    apiKey,
    model,
    configured: Boolean(baseUrl && (apiKey || provider === "ollama")),
    featureEnabled: dbConfig.enabled,
  };
}

interface EventRowForTips {
  id: string;
  title: string;
  description: string | null;
  age_min: number | null;
  age_max: number | null;
  is_outdoor: boolean | null;
  venue_name: string | null;
  start_datetime: string;
}

async function loadEventContext(
  supabase: SupabaseClient,
  eventId: string,
): Promise<ParentTipsEventContext> {
  const { data: eventRow, error: eventError } = await supabase
    .from("events")
    .select(
      "id, title, description, age_min, age_max, is_outdoor, venue_name, start_datetime",
    )
    .eq("id", eventId)
    .maybeSingle();

  if (eventError) throw eventError;
  if (!eventRow) {
    throw new GenerateParentTipsRequestError(`event ${eventId} not found`, 404);
  }

  const event = eventRow as EventRowForTips;

  const { data: tagRows, error: tagsError } = await supabase
    .from("event_tags")
    .select("confidence, tags(slug)")
    .eq("event_id", eventId)
    .order("confidence", { ascending: false });

  if (tagsError) throw tagsError;

  // The implicit join `tags(slug)` from Supabase-js is typed as an array by
  // the generator even though FK side is single. Normalize both shapes.
  const tagSlugs = ((tagRows ?? []) as Array<{
    tags: { slug: string } | { slug: string }[] | null;
  }>)
    .flatMap((row) => {
      if (!row.tags) return [] as string[];
      if (Array.isArray(row.tags)) {
        return row.tags.map((t) => t.slug).filter(Boolean);
      }
      return row.tags.slug ? [row.tags.slug] : [];
    });

  return {
    title: event.title,
    description: event.description,
    ageMin: event.age_min,
    ageMax: event.age_max,
    isOutdoor: event.is_outdoor,
    venueName: event.venue_name,
    startDatetime: event.start_datetime,
    tagSlugs,
  };
}

interface LlmCallResult {
  tips: ParentTipRecord[];
  finishReason: string | null;
  latencyMs: number;
  promptTokens: number | null;
  completionTokens: number | null;
  totalTokens: number | null;
}

async function generateWithLlm(
  config: LlmConfig,
  ctx: ParentTipsEventContext,
): Promise<LlmCallResult> {
  const systemPrompt = buildSystemPrompt();
  const userPrompt = buildUserPrompt(ctx);

  const start = Date.now();
  const response = await fetch(`${config.baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: config.model,
      temperature: 0.2,
      response_format: config.provider === "openai"
        ? {
            type: "json_schema" as const,
            json_schema: {
              name: "parent_tips",
              strict: true,
              schema: PARENT_TIPS_JSON_SCHEMA,
            },
          }
        : { type: "json_object" as const },
      ...(config.provider === "ollama" ? { reasoning_effort: "none" } : {}),
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
    }),
    signal: AbortSignal.timeout(AI_TIMEOUT_MS),
  });

  if (!response.ok) {
    const errorBody = await response.text().catch(() => "");
    throw new Error(
      `${config.provider} parent-tips call failed (${response.status}): ${
        errorBody.slice(0, 200)
      }`,
    );
  }

  const completion = await response.json();
  const latencyMs = Date.now() - start;
  const rawContent = completion?.choices?.[0]?.message?.content;
  if (!rawContent) {
    throw new Error(`${config.provider} returned an empty response`);
  }

  const parsed = JSON.parse(rawContent);
  const rawTips = Array.isArray(parsed?.tips) ? parsed.tips : [];

  const allowed = new Set<string>(ALLOWED_PARENT_TIP_CATEGORIES);
  const seenCategories = new Set<string>();
  const tips: ParentTipRecord[] = [];
  for (const entry of rawTips) {
    if (!isRecord(entry)) continue;
    const category = typeof entry.category === "string" ? entry.category : "";
    const text = typeof entry.text === "string" ? entry.text.trim() : "";
    if (!allowed.has(category)) continue;
    if (text.length === 0) continue;
    if (seenCategories.has(category)) continue;
    tips.push({ category, text });
    seenCategories.add(category);
    if (tips.length === 3) break;
  }

  if (tips.length === 0) {
    throw new Error("model returned no valid parent tips");
  }

  const usageRaw = completion?.usage ?? {};
  return {
    tips,
    finishReason: typeof completion?.choices?.[0]?.finish_reason === "string"
      ? completion.choices[0].finish_reason
      : null,
    latencyMs,
    promptTokens: Number.isFinite(usageRaw.prompt_tokens)
      ? Number(usageRaw.prompt_tokens)
      : null,
    completionTokens: Number.isFinite(usageRaw.completion_tokens)
      ? Number(usageRaw.completion_tokens)
      : null,
    totalTokens: Number.isFinite(usageRaw.total_tokens)
      ? Number(usageRaw.total_tokens)
      : null,
  };
}

interface HandlerDeps {
  createSupabaseClient: (url: string, key: string) => SupabaseClient;
  requireServiceRole: typeof requireServiceRole;
  getEnv: (name: string) => string | undefined;
  loadFeatureConfig: typeof loadParentTipsFeatureConfig;
  loadEventContext: typeof loadEventContext;
  generateWithLlm: typeof generateWithLlm;
}

const defaultDeps: HandlerDeps = {
  createSupabaseClient: (url, key) => createClient(url, key),
  requireServiceRole,
  getEnv: (name) => Deno.env.get(name),
  loadFeatureConfig: loadParentTipsFeatureConfig,
  loadEventContext,
  generateWithLlm,
};

export function createGenerateParentTipsHandler(
  overrides: Partial<HandlerDeps> = {},
): (req: Request) => Promise<Response> {
  const deps: HandlerDeps = { ...defaultDeps, ...overrides };

  return async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders });
    }

    const serviceRoleKey = deps.getEnv("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const auth = deps.requireServiceRole(req, serviceRoleKey);
    if (!auth.ok) {
      return jsonResponse({ error: auth.message }, auth.status);
    }

    const supabaseUrl = deps.getEnv("SUPABASE_URL") ?? "";
    if (!supabaseUrl) {
      return jsonResponse({ error: "SUPABASE_URL not configured" }, 500);
    }

    const startedAt = Date.now();

    try {
      const supabase = deps.createSupabaseClient(supabaseUrl, serviceRoleKey);
      const body = await req.json().catch(() => ({}));
      const eventId = isRecord(body) && typeof body.event_id === "string"
        ? body.event_id
        : null;
      if (!eventId) {
        throw new GenerateParentTipsRequestError("event_id is required");
      }

      const featureConfig = await deps.loadFeatureConfig(supabase);
      const llmConfig = resolveAiConfig(featureConfig);

      if (!llmConfig.featureEnabled) {
        return jsonResponse(
          { error: "parent-tips feature disabled" },
          503,
        );
      }
      if (!llmConfig.configured) {
        // Bump attempt timestamp so the row rotates out of the claim queue.
        await supabase.rpc("mark_event_enrichment_attempt", {
          p_event_id: eventId,
        });
        return jsonResponse(
          { error: "AI provider not configured" },
          503,
        );
      }

      const ctx = await deps.loadEventContext(supabase, eventId);
      const result = await deps.generateWithLlm(llmConfig, ctx);

      const { error: updateError } = await supabase.rpc(
        "update_event_parent_tips",
        {
          p_event_id: eventId,
          p_tips: result.tips,
          p_provider: llmConfig.provider,
          p_model: llmConfig.model,
          p_prompt_version: LLM_PARENT_TIPS_PROMPT_VERSION,
        },
      );
      if (updateError) throw updateError;

      logEdgeEvent("log", "generate-parent-tips success", {
        function: "generate-parent-tips",
        event_id: eventId,
        provider: llmConfig.provider,
        model: llmConfig.model,
        prompt_version: LLM_PARENT_TIPS_PROMPT_VERSION,
        tip_count: result.tips.length,
        categories: result.tips.map((t: ParentTipRecord) => t.category),
        prompt_tokens: result.promptTokens,
        completion_tokens: result.completionTokens,
        total_tokens: result.totalTokens,
        llm_ms: result.latencyMs,
        total_ms: Date.now() - startedAt,
        finish_reason: result.finishReason,
      });

      return jsonResponse({
        ok: true,
        event_id: eventId,
        tips: result.tips,
        provider: llmConfig.provider,
        model: llmConfig.model,
        prompt_version: LLM_PARENT_TIPS_PROMPT_VERSION,
      });
    } catch (err) {
      if (err instanceof GenerateParentTipsRequestError) {
        return jsonResponse({ error: err.message }, err.status);
      }

      const context = errorContext(err, {
        function: "generate-parent-tips",
      });
      await captureEdgeException(err, context);
      logEdgeEvent("error", "generate-parent-tips failed", context);

      return jsonResponse({ error: errorMessage(err) }, 500);
    }
  };
}

export const handleGenerateParentTips = createGenerateParentTipsHandler();

// Re-export for tests / external callers if needed.
export type { ParentTipCategory };
