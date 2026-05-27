import { existsSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { loadConfig, repoRootFrom } from "../src/core/config"
import { runDeploy } from "../src/workflows/deploy-runner"

describe("deploy runner", () => {
  it("writes a dry-run artifact without provider mutations", async () => {
    const rootDir = repoRootFrom()
    const result = await runDeploy(rootDir, loadConfig(rootDir), {
      env: "production",
      all: true,
      targets: [],
      dryRun: true,
      yes: true,
      interactive: false,
      json: true,
      verbose: false,
      debug: false,
      color: false,
      poll: true,
      smoke: false,
      allowProdSmoke: false,
    })
    expect(result.targets.length).toBeGreaterThan(3)
    expect(result.targets.every((target) => target.status === "success")).toBe(true)
    expect(result.artifactPath ? existsSync(result.artifactPath) : false).toBe(true)
  })
})
