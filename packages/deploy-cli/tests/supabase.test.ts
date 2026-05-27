import { describe, expect, it } from "vitest"
import { loadConfig, repoRootFrom } from "../src/core/config"
import { SupabaseProvider } from "../src/providers/supabase"
import type { CommandRecord, ProcessResult, ProcessRunner } from "../src/core/types"

class FakeRunner implements ProcessRunner {
  records: CommandRecord[] = []
  async run(command: string, args: string[]): Promise<ProcessResult> {
    this.records.push({ command, args, cwd: repoRootFrom(), dryRun: false, exitCode: 0 })
    return { stdout: "", stderr: "", exitCode: 0 }
  }
}

describe("Supabase provider", () => {
  it("discovers the configured functions without drift", () => {
    const rootDir = repoRootFrom()
    const config = loadConfig(rootDir)
    const provider = new SupabaseProvider(rootDir, config, new FakeRunner())
    expect(provider.discoverFunctions()).toEqual([...config.supabase.functions].sort())
  })

  it("applies no-verify-jwt only to configured functions", () => {
    const rootDir = repoRootFrom()
    const config = loadConfig(rootDir)
    process.env.SUPABASE_PROJECT_REF = "project"
    const provider = new SupabaseProvider(rootDir, config, new FakeRunner())
    expect(provider.functionDeployArgs("tag-event", "production")).toContain("--no-verify-jwt")
    expect(provider.functionDeployArgs("share-og", "production")).not.toContain("--no-verify-jwt")
    delete process.env.SUPABASE_PROJECT_REF
  })
})
