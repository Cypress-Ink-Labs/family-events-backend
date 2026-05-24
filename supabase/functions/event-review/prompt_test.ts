import { assertEquals, assertMatch, assertStringIncludes } from "jsr:@std/assert";
import {
  ADMIN_REVIEW_EDGE_CASES,
  APPROVAL_CRITERIA,
  buildReviewPrompt,
  FLAGS,
  LLM_EVENT_REVIEW_PROMPT_VERSION,
  REJECTION_CRITERIA,
} from "./prompt.ts";

const baseInput = {
  eventId: "event-1",
  title: "Family Story Time",
  description: "Bring your kids for books and songs.",
  startDatetime: "2026-06-01T14:00:00Z",
  endDatetime: null,
  timezone: "America/Chicago",
  venueName: "Main Library",
  address: "10 Main St",
  sourceName: "Library Feed",
  sourceUrl: "https://example.com/event/1",
  category: "storytime",
  tags: ["storytime"],
};

Deno.test("prompt contains approval criteria", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, APPROVAL_CRITERIA[0]);
});

Deno.test("prompt contains rejection criteria", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, REJECTION_CRITERIA[0]);
});

Deno.test("prompt contains admin-review edge cases", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, ADMIN_REVIEW_EDGE_CASES[0]);
});

Deno.test("prompt includes strict JSON schema contract", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, "Return JSON ONLY using this exact schema");
  assertStringIncludes(prompt.systemPrompt, "approve|reject|needs_admin_review");
});

Deno.test("prompt delimiters untrusted event data", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertMatch(prompt.userPrompt, /BEGIN_UNTRUSTED_EVENT_JSON/);
  assertMatch(prompt.userPrompt, /END_UNTRUSTED_EVENT_JSON/);
});

Deno.test("prompt version is exported and stable", () => {
  assertEquals(LLM_EVENT_REVIEW_PROMPT_VERSION, "event-review-v2");
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, LLM_EVENT_REVIEW_PROMPT_VERSION);
});

Deno.test("prompt contains security rules", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, "Security rules:");
  assertStringIncludes(prompt.systemPrompt, "untrusted data");
  assertStringIncludes(prompt.systemPrompt, "prompt_injection_attempt");
});

Deno.test("prompt contains output rules", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, "Output rules:");
  assertStringIncludes(prompt.systemPrompt, "Return valid JSON only");
});

Deno.test("prompt contains decision criteria sections", () => {
  const prompt = buildReviewPrompt(baseInput);
  assertStringIncludes(prompt.systemPrompt, "Approve when all are true:");
  assertStringIncludes(prompt.systemPrompt, "Reject when any are clearly true:");
  assertStringIncludes(prompt.systemPrompt, "Use needs_admin_review when:");
});

Deno.test("prompt contains flags list", () => {
  const prompt = buildReviewPrompt(baseInput);
  for (const flag of FLAGS) {
    assertStringIncludes(prompt.systemPrompt, `"${flag}"`);
  }
});
