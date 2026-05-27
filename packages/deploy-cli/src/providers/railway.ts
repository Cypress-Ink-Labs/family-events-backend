import { existsSync } from "node:fs"
import path from "node:path"
import { AuthError, ValidationError } from "../core/errors"
import { requireExecutable, requireRailwayAuth } from "../core/exec"
import type { DeployConfig, ProcessRunner, RailwayServiceConfig } from "../core/types"

type RailwayStatus =
  | "SUCCESS"
  | "FAILED"
  | "CRASHED"
  | "BUILDING"
  | "DEPLOYING"
  | "INITIALIZING"
  | "QUEUED"
  | "UNKNOWN"

export class RailwayProvider {
  private readonly rootDir: string
  private readonly config: DeployConfig
  private readonly runner: ProcessRunner

  constructor(rootDir: string, config: DeployConfig, runner: ProcessRunner) {
    this.rootDir = rootDir
    this.config = config
    this.runner = runner
  }

  async preflight(): Promise<void> {
    await requireExecutable(this.runner, "railway")
    await requireRailwayAuth(this.runner)
  }

  serviceConfig(name: string): RailwayServiceConfig {
    const service = this.config.railway.services.find((candidate) => candidate.name === name)
    if (!service) {
      throw new ValidationError(`Unknown Railway service: ${name}`)
    }
    return service
  }

  async serviceExists(name: string): Promise<boolean> {
    const result = await this.runner.run("railway", ["service", "list", "--json"], {
      allowFailure: true,
    })
    if (result.exitCode !== 0 || !result.stdout.trim()) {
      throw new AuthError("Could not list Railway services")
    }
    const parsed = JSON.parse(result.stdout) as unknown
    return extractServiceNames(parsed).includes(name)
  }

  async deployService(
    name: string,
    options: { poll: boolean; pollTimeoutSeconds?: number; noPollSuccess?: boolean }
  ): Promise<void> {
    const service = this.serviceConfig(name)
    this.validateServiceDirectory(service)

    if (!(await this.serviceExists(name))) {
      if (!service.allowAutoCreate || service.rootDirectory === null) {
        throw new ValidationError(
          `Railway service '${name}' was not found and cannot be auto-created`
        )
      }
      await this.runner.run("railway", ["add", `--service=${name}`, "--json"])
      await this.bootstrapCreatedService(service)
    }

    await this.runner.run("railway", ["up", "--service", name, "--detach"], { cwd: this.rootDir })
    if (options.poll) {
      await this.pollStatus(
        name,
        options.pollTimeoutSeconds ?? service.pollTimeoutSeconds,
        options.noPollSuccess ?? false
      )
    }
  }

  async status(name: string): Promise<RailwayStatus> {
    const result = await this.runner.run(
      "railway",
      ["service", "status", "--service", name, "--json"],
      {
        cwd: this.rootDir,
        allowFailure: true,
      }
    )
    if (result.exitCode !== 0 || !result.stdout.trim()) {
      return "UNKNOWN"
    }
    return parseRailwayStatus(result.stdout)
  }

  async pollStatus(name: string, timeoutSeconds: number, noPollSuccess: boolean): Promise<void> {
    const intervalSeconds = 10
    let elapsed = 0

    while (elapsed < timeoutSeconds) {
      const status = await this.status(name)
      if (status === "SUCCESS") return
      if (status === "FAILED" || status === "CRASHED") {
        throw new ValidationError(`Railway service '${name}' deploy ${status}`)
      }
      if (status === "UNKNOWN") return
      await new Promise((resolve) => setTimeout(resolve, intervalSeconds * 1000))
      elapsed += intervalSeconds
    }

    const finalStatus = await this.status(name)
    if (finalStatus === "SUCCESS" || noPollSuccess) return
    throw new ValidationError(`Railway poll timed out for '${name}' (last status: ${finalStatus})`)
  }

  private validateServiceDirectory(service: RailwayServiceConfig): void {
    if (service.rootDirectory === null) return
    if (!existsSync(path.join(this.rootDir, service.rootDirectory))) {
      throw new ValidationError(
        `Directory not found for Railway service '${service.name}': ${service.rootDirectory}`
      )
    }
  }

  private async bootstrapCreatedService(service: RailwayServiceConfig): Promise<void> {
    if (service.name !== "cron-review-events" || !service.bootstrapFromService) return

    const result = await this.runner.run(
      "railway",
      ["variable", "list", "--service", service.bootstrapFromService, "--json"],
      {
        allowFailure: true,
      }
    )
    if (result.exitCode !== 0 || !result.stdout.trim()) {
      return
    }
    const vars = JSON.parse(result.stdout) as Record<string, string | undefined>
    for (const key of ["SUPABASE_SERVICE_ROLE_KEY", "IS_CRON_ENABLED_URL", "LOG_CRON_RUN_URL"]) {
      const value = vars[key]
      if (value) {
        await this.runner.run("railway", [
          "variable",
          "set",
          "--service",
          service.name,
          "--skip-deploys",
          "--json",
          `${key}=${value}`,
        ])
      }
    }

    const sourceUrl = vars.BACKFILL_EVENT_ENRICHMENT_URL
    if (sourceUrl) {
      const processUrl = sourceUrl.replace(
        /\/functions\/v1\/backfill-event-enrichment$/,
        "/functions/v1/process-event-review-queue"
      )
      await this.runner.run("railway", [
        "variable",
        "set",
        "--service",
        service.name,
        "--skip-deploys",
        "--json",
        `PROCESS_EVENT_REVIEW_QUEUE_URL=${processUrl}`,
      ])
    }
  }
}

export function parseRailwayStatus(raw: string): RailwayStatus {
  const parsed = JSON.parse(raw) as unknown
  const status = findStatus(parsed)
  switch (status) {
    case "SUCCESS":
    case "FAILED":
    case "CRASHED":
    case "BUILDING":
    case "DEPLOYING":
    case "INITIALIZING":
    case "QUEUED":
      return status
    default:
      return "UNKNOWN"
  }
}

function findStatus(value: unknown): string | undefined {
  if (!value || typeof value !== "object") return undefined
  if ("status" in value && typeof value.status === "string") return value.status
  if ("deployment" in value) return findStatus(value.deployment)
  if ("latestDeployment" in value) return findStatus(value.latestDeployment)
  if ("deployments" in value && Array.isArray(value.deployments)) {
    return findStatus(value.deployments[0])
  }
  return undefined
}

function extractServiceNames(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map((item) => (typeof item === "object" && item && "name" in item ? String(item.name) : ""))
    .filter(Boolean)
}
