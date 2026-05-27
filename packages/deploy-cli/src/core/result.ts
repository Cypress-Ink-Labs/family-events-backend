import type { TargetResult } from "./types"

export function createTargetResult(targetId: string, startedAt: Date): TargetResult {
  const now = new Date().toISOString()
  return {
    targetId,
    status: "skipped",
    startedAt: startedAt.toISOString(),
    finishedAt: now,
    commands: [],
  }
}

export function finishTarget(
  result: TargetResult,
  status: TargetResult["status"],
  fields: Partial<Omit<TargetResult, "targetId" | "startedAt" | "status">> = {}
): TargetResult {
  return {
    ...result,
    ...fields,
    status,
    finishedAt: new Date().toISOString(),
  }
}
