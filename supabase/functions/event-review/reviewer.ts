import { resolveLlmReviewConfig } from "./config.ts";
import { normalizeReviewEventInput } from "./normalizer.ts";
import { buildReviewPrompt } from "./prompt.ts";
import {
  applyConfidenceThreshold,
  parseLlmDecisionJson,
} from "./schema.ts";
import { buildLlmReviewProvider } from "./provider.ts";
import type {
  AppliedLlmEventReviewDecision,
  ReviewEventDeps,
  ReviewEventInput,
  LlmReviewConfig,
} from "./types.ts";

function failedDecision(
  config: LlmReviewConfig,
  reason: string,
  errorCode: string,
  processingMs: number,
  errorMessage: string | null = null,
): AppliedLlmEventReviewDecision {
  return {
    status: "failed",
    modelDecision: null,
    appliedDecision: "needs_admin_review",
    confidence: null,
    reason,
    flags: [errorCode],
    suggestedCategory: null,
    normalizedTitle: null,
    provider: config.provider,
    model: config.model,
    promptVersion: config.promptVersion,
    rawResponse: null,
    errorCode,
    errorMessage,
    processingMs,
  };
}

export async function reviewEventWithLlm(
  input: ReviewEventInput,
  deps?: Partial<ReviewEventDeps>,
): Promise<AppliedLlmEventReviewDecision> {
  const startedAt = deps?.now?.() ?? Date.now();
  const config = deps?.config ?? resolveLlmReviewConfig();

  if (!config.enabled) {
    const elapsed = (deps?.now?.() ?? Date.now()) - startedAt;
    return failedDecision(
      config,
      "LLM review is disabled; routing to admin review.",
      "disabled",
      elapsed,
    );
  }

  if (!config.valid) {
    const elapsed = (deps?.now?.() ?? Date.now()) - startedAt;
    return failedDecision(
      config,
      "LLM review configuration is invalid; routing to admin review.",
      config.invalidReason ?? "invalid_config",
      elapsed,
      config.invalidReason,
    );
  }

  const normalized = normalizeReviewEventInput(input);
  if (!normalized.normalized || normalized.fallback) {
    const elapsed = (deps?.now?.() ?? Date.now()) - startedAt;
    return failedDecision(
      config,
      normalized.fallback?.reason ??
        "Input is incomplete for automated review; routing to admin review.",
      normalized.fallback?.code ?? "invalid_input",
      elapsed,
    );
  }

  const prompt = buildReviewPrompt(normalized.normalized);
  const provider = deps?.provider ?? buildLlmReviewProvider(config);

  try {
    const providerOutput = await provider.review(
      {
        systemPrompt: prompt.systemPrompt,
        userPrompt: prompt.userPrompt,
        model: config.model,
      },
      AbortSignal.timeout(config.timeoutMs),
    );

    const parsed = parseLlmDecisionJson(providerOutput.rawText);
    const applied = applyConfidenceThreshold(parsed, config.confidenceThreshold);
    const elapsed = (deps?.now?.() ?? Date.now()) - startedAt;

    return {
      status: "succeeded",
      modelDecision: applied.modelDecision,
      appliedDecision: applied.appliedDecision,
      confidence: applied.confidence,
      reason: applied.reason,
      flags: applied.lowConfidence
        ? [...new Set([...applied.flags, "low_confidence"])]
        : applied.flags,
      suggestedCategory: applied.suggestedCategory,
      normalizedTitle: applied.normalizedTitle,
      provider: providerOutput.provider,
      model: providerOutput.model,
      promptVersion: config.promptVersion,
      rawResponse: config.persistRawResponse ? providerOutput.rawResponse : null,
      errorCode: null,
      errorMessage: null,
      processingMs: elapsed,
    };
  } catch (error) {
    const elapsed = (deps?.now?.() ?? Date.now()) - startedAt;
    const message = error instanceof Error ? error.message : String(error);
    const errorCode = message.includes("timeout")
      ? "provider_timeout"
      : message.startsWith("provider_http_")
      ? "provider_http_error"
      : message === "invalid_json"
      ? "malformed_json"
      : message.startsWith("invalid_") || message.startsWith("unexpected_key")
      ? "schema_validation_error"
      : "provider_error";

    return failedDecision(
      config,
      "Automated review failed; routing to admin review.",
      errorCode,
      elapsed,
      message,
    );
  }
}
