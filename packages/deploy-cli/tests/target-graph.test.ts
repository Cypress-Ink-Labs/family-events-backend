import { describe, expect, it } from "vitest"
import type { DeployConfig } from "../src/core/types"
import { resolveTargets } from "../src/core/target-graph"

const config: DeployConfig = {
  environments: {
    production: { supabase: { projectRefFile: "ref", projectRefEnv: "SUPABASE_PROJECT_REF" } },
  },
  supabase: { functions: ["a", "b"], noVerifyJwtFunctions: ["b"] },
  railway: {
    allOrder: ["web", "cron"],
    services: [
      { name: "web", rootDirectory: null, pollTimeoutSeconds: 600, allowAutoCreate: false },
      { name: "cron", rootDirectory: "apps/cron", pollTimeoutSeconds: 300, allowAutoCreate: true },
    ],
  },
  smoke: { functionDrift: true, cronEnabledProbe: { enabledWhenEnvPresent: true, label: "cron" } },
}

describe("target graph", () => {
  it("deduplicates all-function and child function targets", () => {
    expect(
      resolveTargets(config, ["supabase:functions:all", "supabase:function:a"], false).map(
        (target) => target.id
      )
    ).toEqual(["supabase:functions:all"])
  })

  it("normalizes bare service names as Railway targets", () => {
    expect(resolveTargets(config, ["web"], false)[0]?.id).toBe("railway:web")
  })

  it("resolves all to top-level grouped targets", () => {
    expect(resolveTargets(config, [], true).map((target) => target.id)).toEqual([
      "supabase:migrations",
      "supabase:functions:all",
      "railway:all",
    ])
  })
})
