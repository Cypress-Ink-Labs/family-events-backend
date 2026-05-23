import type { EventTagQueueStatus } from "../../../packages/contracts/src/database-enums.ts";

export function resolveCompletedTagQueueStatus(): EventTagQueueStatus {
  return "succeeded";
}

export function shouldStopBeforeStartingNextTagRow(
  elapsedMs: number,
  budgetMs: number,
): boolean {
  return elapsedMs >= budgetMs - 5_000;
}
