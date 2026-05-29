import { assertEquals } from "jsr:@std/assert";
import {
  formatTagMemoryPrompt,
  formatReviewMemoryPrompt,
  type SimilarEventTagContext,
  type SimilarEventReviewContext,
} from "./memory-context.ts";

// ── formatTagMemoryPrompt tests ──────────────────────────────────────────────

Deno.test("formatTagMemoryPrompt - returns empty string for no contexts", () => {
  assertEquals(formatTagMemoryPrompt([]), "");
});

Deno.test("formatTagMemoryPrompt - formats single event with AI tags", () => {
  const contexts: SimilarEventTagContext[] = [
    {
      eventId: "evt-1",
      title: "Kids Music Class",
      cosineDistance: 0.12,
      tags: [
        { slug: "music", name: "Music", source: "ai", confidence: 0.9 },
        { slug: "indoor", name: "Indoor", source: "ai", confidence: 0.7 },
      ],
      adminCorrected: false,
      adminReason: null,
    },
  ];

  const result = formatTagMemoryPrompt(contexts);
  assertEquals(result.includes("MEMORY CONTEXT"), true);
  assertEquals(result.includes("Kids Music Class"), true);
  assertEquals(result.includes("music"), true);
  assertEquals(result.includes("indoor"), true);
  assertEquals(result.includes("admin-corrected"), false);
});

Deno.test("formatTagMemoryPrompt - highlights admin corrections", () => {
  const contexts: SimilarEventTagContext[] = [
    {
      eventId: "evt-2",
      title: "Art Workshop for Families",
      cosineDistance: 0.15,
      tags: [
        { slug: "art", name: "Art", source: "admin", confidence: 1.0 },
        { slug: "outdoor", name: "Outdoor", source: "ai", confidence: 0.8 },
      ],
      adminCorrected: true,
      adminReason: "Added art tag, this is primarily an art event",
    },
  ];

  const result = formatTagMemoryPrompt(contexts);
  assertEquals(result.includes("admin-corrected"), true);
  assertEquals(result.includes("[ADMIN CORRECTED]"), true);
  assertEquals(result.includes("Admin reason:"), true);
  assertEquals(result.includes("primarily an art event"), true);
});

Deno.test("formatTagMemoryPrompt - includes reference instruction", () => {
  const contexts: SimilarEventTagContext[] = [
    {
      eventId: "evt-1",
      title: "Test",
      cosineDistance: 0.1,
      tags: [{ slug: "music", name: "Music", source: "ai", confidence: 0.9 }],
      adminCorrected: false,
      adminReason: null,
    },
  ];

  const result = formatTagMemoryPrompt(contexts);
  assertEquals(result.includes("Admin-corrected tags are higher-quality signals"), true);
});

// ── formatReviewMemoryPrompt tests ───────────────────────────────────────────

Deno.test("formatReviewMemoryPrompt - returns empty string for no contexts", () => {
  assertEquals(formatReviewMemoryPrompt([]), "");
});

Deno.test("formatReviewMemoryPrompt - formats approved and rejected events", () => {
  const contexts: SimilarEventReviewContext[] = [
    {
      eventId: "evt-1",
      title: "Kids Yoga",
      cosineDistance: 0.1,
      status: "published",
      llmReviewDecision: "approve",
      adminOverridden: false,
      adminDecision: null,
      adminReason: null,
    },
    {
      eventId: "evt-2",
      title: "Adult Only Event",
      cosineDistance: 0.2,
      status: "rejected",
      llmReviewDecision: "reject",
      adminOverridden: false,
      adminDecision: null,
      adminReason: null,
    },
  ];

  const result = formatReviewMemoryPrompt(contexts);
  assertEquals(result.includes("MEMORY CONTEXT"), true);
  assertEquals(result.includes("Kids Yoga"), true);
  assertEquals(result.includes("published"), true);
  assertEquals(result.includes("Adult Only Event"), true);
  assertEquals(result.includes("rejected"), true);
});

Deno.test("formatReviewMemoryPrompt - highlights admin overrides", () => {
  const contexts: SimilarEventReviewContext[] = [
    {
      eventId: "evt-1",
      title: "Community Garden Day",
      cosineDistance: 0.1,
      status: "published",
      llmReviewDecision: "needs_admin_review",
      adminOverridden: true,
      adminDecision: "published",
      adminReason: "This is a family-friendly community event",
    },
  ];

  const result = formatReviewMemoryPrompt(contexts);
  assertEquals(result.includes("admin-overridden"), true);
  assertEquals(result.includes("Admin reason:"), true);
  assertEquals(result.includes("family-friendly community event"), true);
  assertEquals(result.includes("Admin-overridden decisions are stronger signals"), true);
});
