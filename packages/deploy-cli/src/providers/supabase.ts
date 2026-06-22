import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { ValidationError } from "../core/errors";
import { requireExecutable } from "../core/exec";
import type { DeployConfig, EnvironmentName, ProcessRunner } from "../core/types";
import { resolveProjectRef } from "../core/config";

export class SupabaseProvider {
  private readonly rootDir: string;
  private readonly config: DeployConfig;
  private readonly runner: ProcessRunner;

  constructor(rootDir: string, config: DeployConfig, runner: ProcessRunner) {
    this.rootDir = rootDir;
    this.config = config;
    this.runner = runner;
  }

  async preflight(): Promise<void> {
    await requireExecutable(this.runner, this.supabaseCommand());
  }

  resolveProjectRef(env: EnvironmentName): string {
    const projectRef = resolveProjectRef(this.rootDir, this.config, env);
    if (!projectRef) {
      throw new ValidationError(
        `SUPABASE_PROJECT_REF not set. Run: bash scripts/supabase.sh link --project-ref <ref>`,
      );
    }
    return projectRef;
  }

  discoverFunctions(): string[] {
    const functionsDir = path.join(this.rootDir, "supabase", "functions");
    return readdirSync(functionsDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .filter((name) => name !== "_shared" && name !== "node_modules")
      .filter((name) => existsSync(path.join(functionsDir, name, "index.ts")))
      .sort();
  }

  validateFunctionDrift(): void {
    const discovered = this.discoverFunctions();
    const expected = [...this.config.supabase.functions].sort();
    if (discovered.join("\n") !== expected.join("\n")) {
      throw new ValidationError(
        `Supabase function config drift. Expected: ${expected.join(", ")}. Found: ${discovered.join(", ")}`,
      );
    }
  }

  /**
   * Ensure the Supabase project is linked so `db push --linked` works headlessly
   * in CI. Idempotent: a no-op when `supabase/.temp/project-ref` already matches the
   * resolved ref (the local/dev case where `supabase link` was run manually).
   * Otherwise runs `supabase link --project-ref <ref>`, which requires
   * `SUPABASE_ACCESS_TOKEN` (management API) and reads `SUPABASE_DB_PASSWORD` from the
   * environment for the database connection — both supplied as CI secrets.
   */
  async ensureLinked(env: EnvironmentName): Promise<void> {
    const projectRef = this.resolveProjectRef(env);
    const refFile = path.join(this.rootDir, "supabase", ".temp", "project-ref");
    if (existsSync(refFile) && readFileSync(refFile, "utf8").trim() === projectRef) {
      return;
    }
    if (!process.env.SUPABASE_ACCESS_TOKEN) {
      throw new ValidationError(
        "Supabase project is not linked and SUPABASE_ACCESS_TOKEN is not set. " +
          "Set SUPABASE_ACCESS_TOKEN and SUPABASE_DB_PASSWORD, or run: " +
          "bash scripts/supabase.sh link --project-ref <ref>",
      );
    }
    const result = await this.runner.run(
      this.supabaseCommand(),
      ["link", "--project-ref", projectRef],
      { allowFailure: true },
    );
    if (result.exitCode !== 0) {
      throw new ValidationError(
        `Supabase link failed for project ${projectRef}: ${(result.stderr || result.stdout).trim()}`,
      );
    }
  }

  async deployMigrations(env: EnvironmentName): Promise<void> {
    await this.ensureLinked(env);
    await this.runner.run(this.supabaseCommand(), ["migration", "list", "--linked"], {
      allowFailure: true,
    });
    await this.runner.run(this.supabaseCommand(), ["db", "lint", "--linked"], {
      allowFailure: true,
    });
    await this.runner.run(
      this.supabaseCommand(),
      ["db", "push", "--linked", "--include-all", "--dry-run"],
      {
        allowFailure: true,
      },
    );
    const result = await this.runner.run(
      this.supabaseCommand(),
      ["db", "push", "--linked", "--include-all"],
      {
        allowFailure: true,
      },
    );
    if (
      result.exitCode !== 0 ||
      /(^|\s)ERROR:|Try rerunning the command/.test(`${result.stdout}\n${result.stderr}`)
    ) {
      throw new ValidationError("Supabase migration deploy failed");
    }
  }

  async deployFunction(name: string, env: EnvironmentName): Promise<void> {
    this.assertKnownFunction(name);
    const projectRef = this.resolveProjectRef(env);
    const args = ["functions", "deploy", name, "--project-ref", projectRef];
    if (this.config.supabase.noVerifyJwtFunctions.includes(name)) {
      args.push("--no-verify-jwt");
    }
    await this.runner.run(this.supabaseCommand(), args);
  }

  async listRemoteFunctions(): Promise<string[]> {
    const result = await this.runner.run(this.supabaseCommand(), ["functions", "list", "--json"], {
      allowFailure: true,
    });
    if (result.exitCode !== 0 || !result.stdout.trim()) {
      return [];
    }
    const parsed = JSON.parse(result.stdout) as unknown;
    if (!Array.isArray(parsed)) {
      return [];
    }
    return parsed
      .map((item) => (typeof item === "object" && item && "name" in item ? String(item.name) : ""))
      .filter(Boolean)
      .sort();
  }

  functionDeployArgs(name: string, env: EnvironmentName): string[] {
    const args = ["functions", "deploy", name, "--project-ref", this.resolveProjectRef(env)];
    if (this.config.supabase.noVerifyJwtFunctions.includes(name)) {
      args.push("--no-verify-jwt");
    }
    return args;
  }

  private assertKnownFunction(name: string): void {
    if (!this.config.supabase.functions.includes(name)) {
      throw new ValidationError(`Unknown Supabase function: ${name}`);
    }
  }

  private supabaseCommand(): string {
    return path.join(this.rootDir, "scripts", "supabase.sh");
  }
}
