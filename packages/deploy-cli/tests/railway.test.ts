import { describe, expect, it } from "vitest";
import type { CommandRecord, DeployConfig, ProcessResult, ProcessRunner } from "../src/core/types";
import { parseRailwayStatus, RailwayProvider } from "../src/providers/railway";

class FakeRunner implements ProcessRunner {
  records: CommandRecord[] = [];

  async run(command: string, args: string[]): Promise<ProcessResult> {
    this.records.push({ command, args, cwd: process.cwd(), dryRun: false, exitCode: 0 });
    return { stdout: "", stderr: "", exitCode: 0 };
  }
}

describe("Railway status parser", () => {
  it("parses top-level statuses", () => {
    expect(parseRailwayStatus(JSON.stringify({ status: "SUCCESS" }))).toBe("SUCCESS");
    expect(parseRailwayStatus(JSON.stringify({ status: "FAILED" }))).toBe("FAILED");
    expect(parseRailwayStatus(JSON.stringify({ status: "CRASHED" }))).toBe("CRASHED");
  });

  it("parses nested deployment statuses", () => {
    expect(parseRailwayStatus(JSON.stringify({ latestDeployment: { status: "DEPLOYING" } }))).toBe(
      "DEPLOYING",
    );
    expect(parseRailwayStatus(JSON.stringify({ deployments: [{ status: "QUEUED" }] }))).toBe(
      "QUEUED",
    );
  });

  it("returns UNKNOWN for unsupported shapes", () => {
    expect(parseRailwayStatus(JSON.stringify({ latestDeployment: { state: "done" } }))).toBe(
      "UNKNOWN",
    );
  });
});

describe("Railway provider", () => {
  it("applies Railway IaC before service deploys", async () => {
    const runner = new FakeRunner();
    const config: DeployConfig = {
      environments: {
        production: {
          supabase: { projectRefFile: "supabase/.temp/project-ref", projectRefEnv: "REF" },
        },
      },
      supabase: { functions: [], noVerifyJwtFunctions: [] },
      railway: { allOrder: [], services: [] },
      smoke: {
        functionDrift: false,
        cronEnabledProbe: { enabledWhenEnvPresent: true, label: "cron" },
      },
    };

    await new RailwayProvider(process.cwd(), config, runner).applyConfig();

    expect(runner.records[0]?.command).toBe("railway");
    expect(runner.records[0]?.args).toEqual(["config", "apply", "--yes"]);
  });
});
