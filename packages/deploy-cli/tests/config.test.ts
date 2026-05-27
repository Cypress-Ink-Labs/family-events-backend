import { describe, expect, it } from "vitest"
import { loadConfig, repoRootFrom } from "../src/core/config"

describe("deploy config", () => {
  it("loads the repository config", () => {
    const config = loadConfig(repoRootFrom())
    expect(config.environments.production.supabase.projectRefFile).toBe(
      "supabase/.temp/project-ref"
    )
    expect(config.supabase.functions).toContain("tag-event")
    expect(config.railway.allOrder).toContain("web")
  })
})
