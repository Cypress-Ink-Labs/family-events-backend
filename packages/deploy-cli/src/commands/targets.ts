import type { Command } from "commander"
import { loadConfig, repoRootFrom } from "../core/config"
import { allTargets } from "../core/target-graph"
import { printTargets } from "../ui/output"

export function registerTargetsCommand(program: Command): void {
  program
    .command("targets")
    .option("--json", "emit JSON")
    .action((options: { json?: boolean }) => {
      const rootDir = repoRootFrom()
      printTargets(allTargets(loadConfig(rootDir)), options.json ?? false)
    })
}
