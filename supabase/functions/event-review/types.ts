export type LlmEventReviewDecision =
  | "approve"
  | "reject"
  | "needs_admin_review";

export type LlmEventReviewStatus = "succeeded" | "failed" | "not_required";

export interface LlmEventReviewDecisionPayload {
  decision: LlmEventReviewDecision;
  confidence: number;
  reason: string;
  flags?: string[];
  suggestedCategory?: string;
  normalizedTitle?: string;
}

export interface NormalizedReviewEventInput {
  eventId: string;
  title: string;
  description: string | null;
  startDatetime: string;
  endDatetime: string | null;
  timezone: string | null;
  venueName: string | null;
  address: string | null;
  sourceName: string | null;
  sourceUrl: string | null;
  category: string | null;
  tags: string[];
}

export interface NormalizerFallback {
  code: string;
  reason: string;
}

export interface ReviewNormalizerOutput {
  normalized: NormalizedReviewEventInput | null;
  fallback: NormalizerFallback | null;
}

export interface ReviewEventInput {
  eventId: string;
  title: string | null;
  description: string | null;
  startDatetime: string | null;
  endDatetime: string | null;
  timezone: string | null;
  venueName: string | null;
  address: string | null;
  sourceName: string | null;
  sourceUrl: string | null;
  category: string | null;
  tags: string[];
}

export interface LlmReviewConfig {
  enabled: boolean;
  provider: string;
  baseUrl: string;
  model: string;
  apiKey: string;
  promptVersion: string;
  confidenceThreshold: number;
  timeoutMs: number;
  maxAttempts: number;
  retryBaseMs: number;
  persistRawResponse: boolean;
  valid: boolean;
  invalidReason: string | null;
}

export interface LlmReviewProviderInput {
  systemPrompt: string;
  userPrompt: string;
  model: string;
}

export interface LlmReviewProviderOutput {
  rawText: string;
  rawResponse: unknown;
  provider: string;
  model: string;
}

export interface LlmReviewProvider {
  review(
    input: LlmReviewProviderInput,
    signal: AbortSignal,
  ): Promise<LlmReviewProviderOutput>;
}

export interface AppliedLlmEventReviewDecision {
  status: LlmEventReviewStatus;
  modelDecision: LlmEventReviewDecision | null;
  appliedDecision: LlmEventReviewDecision;
  confidence: number | null;
  reason: string;
  flags: string[];
  suggestedCategory: string | null;
  normalizedTitle: string | null;
  provider: string | null;
  model: string | null;
  promptVersion: string;
  rawResponse: unknown | null;
  errorCode: string | null;
  errorMessage: string | null;
  processingMs: number;
}

export interface ReviewEventDeps {
  config: LlmReviewConfig;
  provider: LlmReviewProvider;
  now?: () => number;
}
