export function resolveCompletedTagQueueStatus(): "succeeded" {
  return "succeeded";
}

export function shouldStopBeforeStartingNextTagRow(
  elapsedMs: number,
  budgetMs: number,
): boolean {
  return elapsedMs >= budgetMs - 5_000;
}
