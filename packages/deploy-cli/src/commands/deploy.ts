import type { Command } from "commander"
import { loadConfig, repoRootFrom } from "../core/config"
import { exitCodeFor, messageFor, ValidationError } from "../core/errors"
import type { DeployOptions, EnvironmentName } from "../core/types"
import { runDeploy } from "../workflows/deploy-runner"
import { pickTargets } from "../ui/interactive"
import { printDeployResult } from "../ui/output"

interface CommanderDeployOptions {
  env?: EnvironmentName
  all?: boolean
  target?: string[]
  dryRun?: boolean
  yes?: boolean
  interactive?: boolean
  json?: boolean
  showOutput?: boolean
  concurrency?: string
  functionConcurrency?: string
  railwayConcurrency?: string
  verbose?: boolean
  debug?: boolean
  color?: boolean
  poll?: boolean
  pollTimeout?: string
  smoke?: boolean
  allowProdSmoke?: boolean
}

export function registerDeployCommand(program: Command): void {
  program
    .command("deploy")
    .argument("[targets...]", "target ids")
    .option("--env <env>", "deployment environment", "production")
    .option("--all", "deploy all configured targets")
    .option("--target <id>", "target id", collect, [])
    .option("--dry-run", "print and record the deploy plan without provider mutations")
    .option("--yes", "skip confirmation prompts")
    .option("--interactive", "force interactive picker")
    .option("--json", "emit JSON")
    .option("--show-output", "show full provider command output instead of spinner-only progress")
    .option("--concurrency <n>", "set both Supabase function and Railway service concurrency")
    .option("--function-concurrency <n>", "Supabase function deploy concurrency")
    .option("--railway-concurrency <n>", "Railway service deploy concurrency")
    .option("--verbose", "verbose output")
    .option("--debug", "debug output")
    .option("--no-color", "disable color")
    .option("--no-poll", "do not poll Railway deployment status")
    .option("--poll-timeout <seconds>", "override Railway poll timeout")
    .option("--smoke", "run post-deploy smoke checks")
    .option("--allow-prod-smoke", "allow production smoke probes that require service keys")
    .action(async (targets: string[], raw: CommanderDeployOptions) => {
      try {
        const rootDir = repoRootFrom()
        const config = loadConfig(rootDir)
        const requestedTargets = [...(raw.target ?? []), ...targets]
        if (!raw.all && requestedTargets.length === 0 && (raw.interactive || process.stdin.isTTY)) {
          requestedTargets.push(...(await pickTargets(config)))
        }

        const options: DeployOptions = {
          env: raw.env ?? "production",
          all: raw.all ?? false,
          targets: requestedTargets,
          dryRun: raw.dryRun ?? false,
          yes: raw.yes ?? false,
          interactive: raw.interactive ?? false,
          json: raw.json ?? false,
          showOutput: (raw.showOutput ?? false) || (raw.verbose ?? false),
          functionConcurrency: parseConcurrency(
            raw.functionConcurrency ?? raw.concurrency,
            "function concurrency",
            4
          ),
          railwayConcurrency: parseConcurrency(
            raw.railwayConcurrency ?? raw.concurrency,
            "Railway concurrency",
            2
          ),
          verbose: raw.verbose ?? false,
          debug: raw.debug ?? false,
          color: raw.color ?? true,
          poll: raw.poll ?? true,
          pollTimeoutSeconds: raw.pollTimeout ? Number.parseInt(raw.pollTimeout, 10) : undefined,
          smoke: raw.smoke ?? false,
          allowProdSmoke: raw.allowProdSmoke ?? false,
        }

        const result = await runDeploy(rootDir, config, options)
        printDeployResult(result, options.json)
      } catch (error) {
        if (raw.json) {
          console.error(JSON.stringify({ error: messageFor(error), exitCode: exitCodeFor(error) }))
        } else {
          console.error(`error: ${messageFor(error)}`)
        }
        process.exitCode = exitCodeFor(error)
      }
    })
}

function collect(value: string, previous: string[]): string[] {
  return [...previous, value]
}

function parseConcurrency(value: string | undefined, label: string, fallback: number): number {
  if (!value) return fallback
  const parsed = Number.parseInt(value, 10)
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new ValidationError(`${label} must be a positive integer`)
  }
  return parsed
}
