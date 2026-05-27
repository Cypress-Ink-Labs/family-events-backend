import type { Command } from "commander"
import { loadConfig, repoRootFrom } from "../core/config"
import { SupabaseProvider } from "../providers/supabase"
import { ExecaProcessRunner } from "../core/exec"

export function registerValidateCommand(program: Command): void {
  program
    .command("validate")
    .option("--env <env>", "deployment environment", "production")
    .option("--json", "emit JSON")
    .action((options: { env?: "production"; json?: boolean }) => {
      const rootDir = repoRootFrom()
      const config = loadConfig(rootDir)
      const supabase = new SupabaseProvider(rootDir, config, new ExecaProcessRunner(rootDir, true))
      supabase.validateFunctionDrift()
      supabase.resolveProjectRef(options.env ?? "production")
      if (options.json) console.log(JSON.stringify({ status: "ok" }))
      else console.log("ok")
    })
}
