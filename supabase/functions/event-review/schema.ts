import type {
  LlmEventReviewDecision,
  LlmEventReviewDecisionPayload,
} from "./types.ts";

const ALLOWED_KEYS = new Set([
  "decision",
  "confidence",
  "reason",
  "flags",
  "suggestedCategory",
  "normalizedTitle",
]);

const DECISIONS: LlmEventReviewDecision[] = [
  "approve",
  "reject",
  "needs_admin_review",
];

const MAX_REASON_CHARS = 1_000;
const MAX_FLAGS = 10;
const MAX_FLAG_CHARS = 80;
const MAX_OPTIONAL_TEXT = 300;

export interface ParsedLlmDecision {
  modelDecision: LlmEventReviewDecision;
  appliedDecision: LlmEventReviewDecision;
  confidence: number;
  reason: string;
  flags: string[];
  suggestedCategory: string | null;
  normalizedTitle: string | null;
  lowConfidence: boolean;
}

function trimToMax(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.length <= max ? trimmed : trimmed.slice(0, max);
}

export function parseLlmDecisionJson(rawJson: string): LlmEventReviewDecisionPayload {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawJson);
  } catch {
    throw new Error("invalid_json");
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("invalid_payload_shape");
  }

  const object = parsed as Record<string, unknown>;
  for (const key of Object.keys(object)) {
    if (!ALLOWED_KEYS.has(key)) {
      throw new Error(`unexpected_key:${key}`);
    }
  }

  const decisionRaw = object.decision;
  if (typeof decisionRaw !== "string" || !DECISIONS.includes(decisionRaw as LlmEventReviewDecision)) {
    throw new Error("invalid_decision");
  }

  const confidenceRaw = Number(object.confidence);
  if (!Number.isFinite(confidenceRaw) || confidenceRaw < 0 || confidenceRaw > 1) {
    throw new Error("invalid_confidence");
  }

  const reason = trimToMax(object.reason, MAX_REASON_CHARS);
  if (!reason) {
    throw new Error("invalid_reason");
  }

  let flags: string[] | undefined;
  if (object.flags !== undefined) {
    if (!Array.isArray(object.flags)) {
      throw new Error("invalid_flags");
    }
    flags = object.flags
      .map((value) => trimToMax(value, MAX_FLAG_CHARS))
      .filter((value): value is string => Boolean(value))
      .slice(0, MAX_FLAGS);
  }

  const suggestedCategory = trimToMax(object.suggestedCategory, MAX_OPTIONAL_TEXT) ?? undefined;
  const normalizedTitle = trimToMax(object.normalizedTitle, MAX_OPTIONAL_TEXT) ?? undefined;

  return {
    decision: decisionRaw as LlmEventReviewDecision,
    confidence: confidenceRaw,
    reason,
    flags,
    suggestedCategory,
    normalizedTitle,
  };
}

export function applyConfidenceThreshold(
  payload: LlmEventReviewDecisionPayload,
  confidenceThreshold: number,
): ParsedLlmDecision {
  const lowConfidence = payload.confidence < confidenceThreshold;
  return {
    modelDecision: payload.decision,
    appliedDecision: lowConfidence ? "needs_admin_review" : payload.decision,
    confidence: payload.confidence,
    reason: payload.reason,
    flags: payload.flags ?? [],
    suggestedCategory: payload.suggestedCategory ?? null,
    normalizedTitle: payload.normalizedTitle ?? null,
    lowConfidence,
  };
}
