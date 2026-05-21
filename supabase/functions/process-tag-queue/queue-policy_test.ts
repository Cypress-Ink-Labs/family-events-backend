import { assertEquals } from "jsr:@std/assert";
import {
  resolveCompletedTagQueueStatus,
  shouldStopBeforeStartingNextTagRow,
} from "./queue-policy.ts";

Deno.test("resolveCompletedTagQueueStatus marks successful jobs succeeded", () => {
  assertEquals(resolveCompletedTagQueueStatus(), "succeeded");
});

Deno.test("shouldStopBeforeStartingNextTagRow stops before budget exhaustion", () => {
  assertEquals(shouldStopBeforeStartingNextTagRow(104_999, 110_000), false);
  assertEquals(shouldStopBeforeStartingNextTagRow(105_000, 110_000), true);
});
