import { assertEquals, assertThrows } from "jsr:@std/assert";
import {
  normalizeArtifactForLlm,
  parseLlmParsedEvents,
  validateParsedEvents,
} from "./extraction-pipeline.ts";
import type { ParsedEvent } from "./types.ts";

const validEvent: ParsedEvent = {
  title: "Story Time",
  description: "Books and songs.",
  startDatetime: "2026-06-01T10:00:00-05:00",
  endDatetime: null,
  venueName: "Library",
  address: null,
  sourceUrl: "https://example.com/events/story-time",
  imageUrl: null,
  images: [],
  price: null,
  isFree: true,
};

Deno.test("validateParsedEvents rejects invalid dates", () => {
  assertEquals(validateParsedEvents([validEvent]).length, 1);
  assertEquals(
    validateParsedEvents([{ ...validEvent, startDatetime: "not-a-date" }])
      .length,
    0,
  );
  assertEquals(
    validateParsedEvents([{ ...validEvent, endDatetime: "not-a-date" }]).length,
    0,
  );
});

Deno.test("parseLlmParsedEvents accepts canonical events and rejects invalid rows", () => {
  assertEquals(parseLlmParsedEvents(JSON.stringify({ events: [validEvent] })), [
    validEvent,
  ]);
  assertThrows(
    () =>
      parseLlmParsedEvents(
        JSON.stringify({ events: [{ ...validEvent, startDatetime: "" }] }),
      ),
    Error,
    "invalid ParsedEvent",
  );
});

Deno.test("normalizeArtifactForLlm caps input size", () => {
  const normalized = normalizeArtifactForLlm({
    url: "https://example.com",
    contentType: "text/html",
    body: "a".repeat(25_000),
  });
  assertEquals(normalized.length, 20_000);
});
