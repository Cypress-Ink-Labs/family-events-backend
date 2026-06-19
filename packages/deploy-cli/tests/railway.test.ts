import { describe, expect, it } from "vitest";
import type { CommandRecord, DeployConfig, ProcessResult, ProcessRunner } from "../src/core/types";
import { countPlannedDeletions, parseRailwayStatus, RailwayProvider } from "../src/providers/railway";

type Responder = (command: string, args: string[]) => ProcessResult;

const ok = (stdout = ""): ProcessResult => ({ stdout, stderr: "", exitCode: 0 });

class FakeRunner implements ProcessRunner {
  records: CommandRecord[] = [];
  private readonly responder: Responder;

  constructor(responder: Responder = () => ok()) {
    this.responder = responder;
  }

  async run(command: string, args: string[]): Promise<ProcessResult> {
    const result = this.responder(command, args);
    this.records.push({ command, args, cwd: process.cwd(), dryRun: false, exitCode: result.exitCode });
    return result;
  }

  ran(args: string[]): boolean {
    return this.records.some((record) => record.args.join(" ") === args.join(" "));
  }
}

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

const planJson = (changes: Array<{ kind: string }>): string =>
  JSON.stringify({ ok: true, command: "plan", changeSet: { version: 0, changes } });

const isPlan = (args: string[]) => args[0] === "config" && args[1] === "plan";

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

describe("countPlannedDeletions", () => {
  it("returns 0 for a non-destructive plan", () => {
    expect(countPlannedDeletions(planJson([]))).toBe(0);
    expect(countPlannedDeletions(planJson([{ kind: "resource.create" }]))).toBe(0);
  });

  it("counts resource deletions", () => {
    expect(
      countPlannedDeletions(
        planJson([{ kind: "resource.delete" }, { kind: "resource.create" }, { kind: "resource.delete" }]),
      ),
    ).toBe(2);
  });

  it("reads preview.changeSet.changes as a fallback", () => {
    const raw = JSON.stringify({ preview: { changeSet: { changes: [{ kind: "resource.delete" }] } } });
    expect(countPlannedDeletions(raw)).toBe(1);
  });

  it("returns null when output is not JSON or has no changeset", () => {
    expect(countPlannedDeletions("IaC runner returned non-JSON output")).toBeNull();
    expect(countPlannedDeletions(JSON.stringify({ ok: true }))).toBeNull();
  });
});

describe("Railway provider applyConfig safety rail", () => {
  it("plans first, then applies when the plan is non-destructive", async () => {
    const runner = new FakeRunner((_cmd, args) => (isPlan(args) ? ok(planJson([])) : ok()));
    await new RailwayProvider(process.cwd(), config, runner).applyConfig();

    expect(runner.records[0]?.args).toEqual(["config", "plan", "--json"]);
    expect(runner.ran(["config", "apply", "--yes"])).toBe(true);
  });

  it("refuses to apply when the plan would delete a service", async () => {
    const runner = new FakeRunner((_cmd, args) =>
      isPlan(args) ? ok(planJson([{ kind: "resource.delete" }])) : ok(),
    );
    await expect(new RailwayProvider(process.cwd(), config, runner).applyConfig()).rejects.toThrow(
      /DELETE/,
    );
    expect(runner.ran(["config", "apply", "--yes"])).toBe(false);
  });

  it("refuses to apply when the plan fails (e.g. CLI / npm version skew)", async () => {
    const runner = new FakeRunner((_cmd, args) =>
      isPlan(args) ? { stdout: "IaC runner returned non-JSON output", stderr: "", exitCode: 1 } : ok(),
    );
    await expect(new RailwayProvider(process.cwd(), config, runner).applyConfig()).rejects.toThrow(
      /Refusing to apply Railway config/,
    );
    expect(runner.ran(["config", "apply", "--yes"])).toBe(false);
  });

  it("refuses to apply when the plan output cannot be parsed", async () => {
    const runner = new FakeRunner((_cmd, args) => (isPlan(args) ? ok("not json at all") : ok()));
    await expect(new RailwayProvider(process.cwd(), config, runner).applyConfig()).rejects.toThrow(
      /could not parse/,
    );
    expect(runner.ran(["config", "apply", "--yes"])).toBe(false);
  });
});

describe("Railway provider deployService", () => {
  const cfg: DeployConfig = {
    ...config,
    railway: {
      allOrder: ["web", "cron-x"],
      services: [
        { name: "web", rootDirectory: null, pollTimeoutSeconds: 600, allowAutoCreate: false },
        { name: "cron-x", rootDirectory: "cron/x", pollTimeoutSeconds: 300, allowAutoCreate: true },
      ],
    },
  };

  it("refuses to deploy an externally-owned service (rootDirectory: null)", async () => {
    const runner = new FakeRunner();
    await expect(
      new RailwayProvider(process.cwd(), cfg, runner).deployService("web", { poll: false }),
    ).rejects.toThrow(/owned by another repo/);
    expect(runner.ran(["up", "--service", "web", "--detach"])).toBe(false);
  });
});
