import { describe, expect, it } from "vitest"
import { parseRailwayStatus } from "../src/providers/railway"

describe("Railway status parser", () => {
  it("parses top-level statuses", () => {
    expect(parseRailwayStatus(JSON.stringify({ status: "SUCCESS" }))).toBe("SUCCESS")
    expect(parseRailwayStatus(JSON.stringify({ status: "FAILED" }))).toBe("FAILED")
    expect(parseRailwayStatus(JSON.stringify({ status: "CRASHED" }))).toBe("CRASHED")
  })

  it("parses nested deployment statuses", () => {
    expect(parseRailwayStatus(JSON.stringify({ latestDeployment: { status: "DEPLOYING" } }))).toBe(
      "DEPLOYING"
    )
    expect(parseRailwayStatus(JSON.stringify({ deployments: [{ status: "QUEUED" }] }))).toBe(
      "QUEUED"
    )
  })

  it("returns UNKNOWN for unsupported shapes", () => {
    expect(parseRailwayStatus(JSON.stringify({ latestDeployment: { state: "done" } }))).toBe(
      "UNKNOWN"
    )
  })
})
