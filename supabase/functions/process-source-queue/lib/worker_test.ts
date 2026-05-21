import { assertEquals } from "jsr:@std/assert";
import {
  planSourceQueueClaimHandling,
  shouldFallbackToLlm,
  sourceRetryDelayMinutes,
} from "./worker.ts";

Deno.test("sourceRetryDelayMinutes uses bounded exponential backoff", () => {
  assertEquals(sourceRetryDelayMinutes(1), 5);
  assertEquals(sourceRetryDelayMinutes(2), 15);
  assertEquals(sourceRetryDelayMinutes(3), 60);
  assertEquals(sourceRetryDelayMinutes(4), null);
});

Deno.test("planSourceQueueClaimHandling starts one row and releases the rest", () => {
  assertEquals(planSourceQueueClaimHandling([1, 2, 3], 0), {
    start: 1,
    release: [2, 3],
  });
  assertEquals(planSourceQueueClaimHandling([1, 2], 120_000), {
    start: null,
    release: [1, 2],
  });
});

Deno.test("shouldFallbackToLlm only falls back in hybrid mode", () => {
  assertEquals(shouldFallbackToLlm("deterministic_then_llm", 0, null), true);
  assertEquals(shouldFallbackToLlm("deterministic_then_llm", 2, null), false);
  assertEquals(
    shouldFallbackToLlm("deterministic", 0, new Error("parser failed")),
    false,
  );
  assertEquals(shouldFallbackToLlm("llm", 0, null), false);
});
