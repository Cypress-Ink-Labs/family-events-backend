import {
  assertEquals,
  assertThrows,
} from "jsr:@std/assert";
import {
  applyConfidenceThreshold,
  parseLlmDecisionJson,
} from "./schema.ts";

Deno.test("parseLlmDecisionJson accepts valid decision JSON", () => {
  const parsed = parseLlmDecisionJson(
    JSON.stringify({
      decision: "approve",
      confidence: 0.91,
      reason: "Clear family-focused content.",
      flags: ["safe", "clear_details"],
      suggestedCategory: "outdoor",
      normalizedTitle: "Family Story Time",
    }),
  );

  assertEquals(parsed.decision, "approve");
  assertEquals(parsed.confidence, 0.91);
  assertEquals(parsed.flags, ["safe", "clear_details"]);
});

Deno.test("parseLlmDecisionJson rejects invalid decision", () => {
  assertThrows(
    () =>
      parseLlmDecisionJson(
        JSON.stringify({
          decision: "publish",
          confidence: 0.9,
          reason: "invalid",
        }),
      ),
    Error,
    "invalid_decision",
  );
});

Deno.test("parseLlmDecisionJson rejects confidence below 0", () => {
  assertThrows(
    () =>
      parseLlmDecisionJson(
        JSON.stringify({
          decision: "approve",
          confidence: -0.01,
          reason: "bad",
        }),
      ),
    Error,
    "invalid_confidence",
  );
});

Deno.test("parseLlmDecisionJson rejects confidence above 1", () => {
  assertThrows(
    () =>
      parseLlmDecisionJson(
        JSON.stringify({
          decision: "approve",
          confidence: 1.01,
          reason: "bad",
        }),
      ),
    Error,
    "invalid_confidence",
  );
});

Deno.test("parseLlmDecisionJson rejects missing reason", () => {
  assertThrows(
    () =>
      parseLlmDecisionJson(
        JSON.stringify({
          decision: "approve",
          confidence: 0.8,
          reason: "   ",
        }),
      ),
    Error,
    "invalid_reason",
  );
});

Deno.test("parseLlmDecisionJson rejects malformed JSON", () => {
  assertThrows(
    () => parseLlmDecisionJson("{invalid-json"),
    Error,
    "invalid_json",
  );
});

Deno.test("applyConfidenceThreshold converts low-confidence to needs_admin_review", () => {
  const applied = applyConfidenceThreshold(
    {
      decision: "reject",
      confidence: 0.61,
      reason: "Uncertain quality",
      flags: ["uncertain"],
    },
    0.75,
  );

  assertEquals(applied.modelDecision, "reject");
  assertEquals(applied.appliedDecision, "needs_admin_review");
  assertEquals(applied.lowConfidence, true);
});

Deno.test("applyConfidenceThreshold preserves model decision when above threshold", () => {
  const applied = applyConfidenceThreshold(
    {
      decision: "reject",
      confidence: 0.85,
      reason: "Clear spam signals",
      flags: [],
    },
    0.75,
  );

  assertEquals(applied.modelDecision, "reject");
  assertEquals(applied.appliedDecision, "reject");
  assertEquals(applied.lowConfidence, false);
});
