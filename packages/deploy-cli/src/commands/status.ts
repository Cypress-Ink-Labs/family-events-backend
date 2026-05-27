import type { Command } from "commander"
import { loadConfig, repoRootFrom } from "../core/config"
import { ExecaProcessRunner } from "../core/exec"
import { RailwayProvider } from "../providers/railway"
import { normalizeTargetId } from "../core/target-graph"

export function registerStatusCommand(program: Command): void {
  program
    .command("status")
    .argument("[targets...]", "Railway target ids")
    .option("--json", "emit JSON")
    .action(async (targets: string[], options: { json?: boolean }) => {
      const rootDir = repoRootFrom()
      const config = loadConfig(rootDir)
      const railway = new RailwayProvider(rootDir, config, new ExecaProcessRunner(rootDir, false))
      const serviceNames =
        targets.length > 0
          ? targets.map((target) => normalizeTargetId(target).replace(/^railway:/, ""))
          : config.railway.allOrder
      const statuses = []
      for (const service of serviceNames) {
        statuses.push({ service, status: await railway.status(service) })
      }
      if (options.json) console.log(JSON.stringify(statuses, null, 2))
      else for (const item of statuses) console.log(`${item.status}\t${item.service}`)
    })
}
