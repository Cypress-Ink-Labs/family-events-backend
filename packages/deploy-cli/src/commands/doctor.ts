import type { Command } from "commander"
import { loadConfig, repoRootFrom } from "../core/config"
import { ExecaProcessRunner, requireExecutable, requireRailwayAuth } from "../core/exec"

export function registerDoctorCommand(program: Command): void {
  program
    .command("doctor")
    .option("--json", "emit JSON")
    .action(async (options: { json?: boolean }) => {
      const rootDir = repoRootFrom()
      loadConfig(rootDir)
      const runner = new ExecaProcessRunner(rootDir, false)
      const checks = []
      for (const executable of [rootDir + "/scripts/supabase.sh", "railway"]) {
        try {
          await requireExecutable(runner, executable)
          checks.push({ name: executable, status: "ok" })
        } catch (error) {
          checks.push({
            name: executable,
            status: "failed",
            message: error instanceof Error ? error.message : String(error),
          })
        }
      }
      try {
        await requireRailwayAuth(runner)
        checks.push({ name: "railway-auth", status: "ok" })
      } catch (error) {
        checks.push({
          name: "railway-auth",
          status: "failed",
          message: error instanceof Error ? error.message : String(error),
        })
      }
      if (options.json) console.log(JSON.stringify({ checks }, null, 2))
      else
        for (const check of checks)
          console.log(
            `${check.status}\t${check.name}${"message" in check ? `\t${check.message}` : ""}`
          )
      process.exitCode = checks.some((check) => check.status === "failed") ? 2 : 0
    })
}
