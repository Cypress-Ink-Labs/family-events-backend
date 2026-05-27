import type { DeployTarget, TargetResult } from "../core/types"

export function rollbackGuidance(target: DeployTarget): string[] {
  if (target.kind === "supabase:migrations") {
    return [
      "Supabase DB rollback is manual. Review supabase/rollbacks/ and apply the matching down script only after data-impact review.",
      "Check Supabase dashboard backups before destructive rollback.",
    ]
  }

  if (target.kind === "supabase:function" && target.name) {
    return [
      `Redeploy a known-good commit for Supabase function '${target.name}'.`,
      "Use git checkout of the known-good revision, then rerun this CLI for the specific function.",
    ]
  }

  if (target.kind === "railway:service" && target.name) {
    return [
      `Use Railway dashboard deployment history to redeploy the last known-good deployment for '${target.name}'.`,
      `After rollback, run: pnpm deploy -- status railway:${target.name}`,
    ]
  }

  return ["Review child target results for rollback guidance."]
}

export function collectRollbackGuidance(results: TargetResult[]): string[] {
  return results.flatMap((result) => result.rollback ?? [])
}
