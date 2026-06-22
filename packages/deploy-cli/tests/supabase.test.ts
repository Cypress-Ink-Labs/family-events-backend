import { describe, expect, it } from "vitest";
import { loadConfig, repoRootFrom } from "../src/core/config";
import { SupabaseProvider } from "../src/providers/supabase";
import type { CommandRecord, ProcessResult, ProcessRunner } from "../src/core/types";

class FakeRunner implements ProcessRunner {
  records: CommandRecord[] = [];
  async run(command: string, args: string[]): Promise<ProcessResult> {
    this.records.push({ command, args, cwd: repoRootFrom(), dryRun: false, exitCode: 0 });
    return { stdout: "", stderr: "", exitCode: 0 };
  }
}

describe("Supabase provider", () => {
  it("discovers the configured functions without drift", () => {
    const rootDir = repoRootFrom();
    const config = loadConfig(rootDir);
    const provider = new SupabaseProvider(rootDir, config, new FakeRunner());
    expect(provider.discoverFunctions()).toEqual([...config.supabase.functions].sort());
  });

  it("applies no-verify-jwt only to configured functions", () => {
    const rootDir = repoRootFrom();
    const config = loadConfig(rootDir);
    process.env.SUPABASE_PROJECT_REF = "project";
    const provider = new SupabaseProvider(rootDir, config, new FakeRunner());
    expect(provider.functionDeployArgs("tag-event", "production")).toContain("--no-verify-jwt");
    expect(provider.functionDeployArgs("weather", "production")).not.toContain("--no-verify-jwt");
    delete process.env.SUPABASE_PROJECT_REF;
  });

  // A synthetic ref that never matches a real `supabase/.temp/project-ref`, so the
  // "already linked" early-return is never taken and these stay deterministic.
  it("ensureLinked throws when unlinked and SUPABASE_ACCESS_TOKEN is missing", async () => {
    const rootDir = repoRootFrom();
    const config = loadConfig(rootDir);
    process.env.SUPABASE_PROJECT_REF = "test-ref-unlinked";
    delete process.env.SUPABASE_ACCESS_TOKEN;
    const provider = new SupabaseProvider(rootDir, config, new FakeRunner());
    await expect(provider.ensureLinked("production")).rejects.toThrow(/SUPABASE_ACCESS_TOKEN/);
    delete process.env.SUPABASE_PROJECT_REF;
  });

  it("ensureLinked runs `supabase link` with the resolved ref when a token is present", async () => {
    const rootDir = repoRootFrom();
    const config = loadConfig(rootDir);
    process.env.SUPABASE_PROJECT_REF = "test-ref-link";
    process.env.SUPABASE_ACCESS_TOKEN = "test-token";
    const runner = new FakeRunner();
    const provider = new SupabaseProvider(rootDir, config, runner);
    await provider.ensureLinked("production");
    const linkCmd = runner.records.find((r) => r.args.includes("link"));
    expect(linkCmd).toBeDefined();
    expect(linkCmd?.args).toContain("test-ref-link");
    delete process.env.SUPABASE_PROJECT_REF;
    delete process.env.SUPABASE_ACCESS_TOKEN;
  });
});
