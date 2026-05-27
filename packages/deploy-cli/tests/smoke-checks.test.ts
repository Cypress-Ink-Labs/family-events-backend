import { describe, expect, it } from "vitest"
import type { DeployConfig, ProcessRunner } from "../src/core/types"
import { SupabaseProvider } from "../src/providers/supabase"
import { runSmokeChecks } from "../src/workflows/smoke-checks"

const config: DeployConfig = {
  environments: {
    production: { supabase: { projectRefFile: "missing", projectRefEnv: "SUPABASE_PROJECT_REF" } },
  },
  supabase: { functions: ["admin-run-cron"], noVerifyJwtFunctions: [] },
  railway: { allOrder: [], services: [] },
  smoke: {
    functionDrift: false,
    cronEnabledProbe: { enabledWhenEnvPresent: true, label: "cron-tag-queue" },
  },
}

const runner: ProcessRunner = {
  records: [],
  async run() {
    return { stdout: "", stderr: "", exitCode: 0 }
  },
}

describe("smoke checks", () => {
  it("skips cron probe without Supabase service env", async () => {
    const provider = new SupabaseProvider(process.cwd(), config, runner)
    const results = await runSmokeChecks(config, provider)
    expect(results).toEqual([
      {
        name: "supabase:is-cron-enabled",
        status: "skipped",
        message: "SUPABASE_URL or SUPABASE_SERVICE_KEY not set",
      },
    ])
  })
})
