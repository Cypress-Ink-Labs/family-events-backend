import type { Command } from "commander"
import { repoRootFrom } from "../core/config"
import { readRunArtifact } from "../core/run-artifacts"
import { collectRollbackGuidance } from "../workflows/rollback"

export function registerRollbackPlanCommand(program: Command): void {
  program
    .command("rollback-plan")
    .requiredOption("--run <run-id>", "run artifact id")
    .option("--json", "emit JSON")
    .action((options: { run: string; json?: boolean }) => {
      const rootDir = repoRootFrom()
      const artifact = readRunArtifact(rootDir, options.run)
      const guidance = collectRollbackGuidance(artifact.targets)
      if (options.json) console.log(JSON.stringify({ runId: artifact.runId, guidance }, null, 2))
      else for (const line of guidance) console.log(line)
    })
}
