import { existsSync, readdirSync } from "node:fs"
import path from "node:path"
import { ValidationError } from "../core/errors"
import { requireExecutable } from "../core/exec"
import type { DeployConfig, EnvironmentName, ProcessRunner } from "../core/types"
import { resolveProjectRef } from "../core/config"

export class SupabaseProvider {
  private readonly rootDir: string
  private readonly config: DeployConfig
  private readonly runner: ProcessRunner

  constructor(rootDir: string, config: DeployConfig, runner: ProcessRunner) {
    this.rootDir = rootDir
    this.config = config
    this.runner = runner
  }

  async preflight(): Promise<void> {
    await requireExecutable(this.runner, this.supabaseCommand())
  }

  resolveProjectRef(env: EnvironmentName): string {
    const projectRef = resolveProjectRef(this.rootDir, this.config, env)
    if (!projectRef) {
      throw new ValidationError(
        `SUPABASE_PROJECT_REF not set. Run: bash scripts/supabase.sh link --project-ref <ref>`
      )
    }
    return projectRef
  }

  discoverFunctions(): string[] {
    const functionsDir = path.join(this.rootDir, "supabase", "functions")
    return readdirSync(functionsDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .filter((name) => name !== "_shared" && name !== "node_modules")
      .filter((name) => existsSync(path.join(functionsDir, name, "index.ts")))
      .sort()
  }

  validateFunctionDrift(): void {
    const discovered = this.discoverFunctions()
    const expected = [...this.config.supabase.functions].sort()
    if (discovered.join("\n") !== expected.join("\n")) {
      throw new ValidationError(
        `Supabase function config drift. Expected: ${expected.join(", ")}. Found: ${discovered.join(", ")}`
      )
    }
  }

  async deployMigrations(): Promise<void> {
    await this.runner.run(this.supabaseCommand(), ["migration", "list", "--linked"], {
      allowFailure: true,
    })
    await this.runner.run(this.supabaseCommand(), ["db", "lint", "--linked"], {
      allowFailure: true,
    })
    await this.runner.run(this.supabaseCommand(), ["db", "push", "--linked", "--dry-run"], {
      allowFailure: true,
    })
    const result = await this.runner.run(this.supabaseCommand(), ["db", "push", "--linked"], {
      allowFailure: true,
    })
    if (
      result.exitCode !== 0 ||
      /(^|\s)ERROR:|Try rerunning the command/.test(`${result.stdout}\n${result.stderr}`)
    ) {
      throw new ValidationError("Supabase migration deploy failed")
    }
  }

  async deployFunction(name: string, env: EnvironmentName): Promise<void> {
    this.assertKnownFunction(name)
    const projectRef = this.resolveProjectRef(env)
    const args = ["functions", "deploy", name, "--project-ref", projectRef]
    if (this.config.supabase.noVerifyJwtFunctions.includes(name)) {
      args.push("--no-verify-jwt")
    }
    await this.runner.run(this.supabaseCommand(), args)
  }

  async listRemoteFunctions(): Promise<string[]> {
    const result = await this.runner.run(this.supabaseCommand(), ["functions", "list", "--json"], {
      allowFailure: true,
    })
    if (result.exitCode !== 0 || !result.stdout.trim()) {
      return []
    }
    const parsed = JSON.parse(result.stdout) as unknown
    if (!Array.isArray(parsed)) {
      return []
    }
    return parsed
      .map((item) => (typeof item === "object" && item && "name" in item ? String(item.name) : ""))
      .filter(Boolean)
      .sort()
  }

  functionDeployArgs(name: string, env: EnvironmentName): string[] {
    const args = ["functions", "deploy", name, "--project-ref", this.resolveProjectRef(env)]
    if (this.config.supabase.noVerifyJwtFunctions.includes(name)) {
      args.push("--no-verify-jwt")
    }
    return args
  }

  private assertKnownFunction(name: string): void {
    if (!this.config.supabase.functions.includes(name)) {
      throw new ValidationError(`Unknown Supabase function: ${name}`)
    }
  }

  private supabaseCommand(): string {
    return path.join(this.rootDir, "scripts", "supabase.sh")
  }
}
