import { assertEquals } from "jsr:@std/assert";
import { resolveProcessingMode } from "./event-processing.ts";
import type { EventSourceRow } from "./types.ts";

function buildSource(overrides: Partial<EventSourceRow> = {}): EventSourceRow {
  return {
    id: "source-1",
    name: "Source",
    url: "https://example.com/feed",
    source_type: "rss",
    extraction_mode: "deterministic",
    processing_mode: "manual_review",
    city_id: null,
    is_active: true,
    auto_approve: false,
    scrape_interval_hours: 24,
    last_scraped_at: null,
    last_status: "pending",
    error_count: 0,
    date_window_days: null,
    ...overrides,
  };
}

Deno.test("resolveProcessingMode uses explicit processing_mode when present", () => {
  assertEquals(
    resolveProcessingMode(buildSource({ processing_mode: "llm_review", auto_approve: false })),
    "llm_review",
  );
});

Deno.test("resolveProcessingMode falls back to auto_approve when processing_mode missing", () => {
  assertEquals(
    resolveProcessingMode(buildSource({ processing_mode: null, auto_approve: true })),
    "auto_approve",
  );
  assertEquals(
    resolveProcessingMode(buildSource({ processing_mode: null, auto_approve: false })),
    "manual_review",
  );
});
