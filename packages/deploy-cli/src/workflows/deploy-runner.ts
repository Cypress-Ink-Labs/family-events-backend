import { ExecaProcessRunner } from "../core/exec"
import { createLogger } from "../core/logger"
import { createRunId, writeRunArtifact } from "../core/run-artifacts"
import { createAbortController } from "../core/signals"
import { expandTarget, resolveTargets } from "../core/target-graph"
import type {
  DeployConfig,
  DeployOptions,
  DeployRunResult,
  DeployTarget,
  SmokeResult,
  TargetResult,
} from "../core/types"
import { SupabaseProvider } from "../providers/supabase"
import { RailwayProvider } from "../providers/railway"
import { finishTarget } from "../core/result"
import { messageFor, SmokeError, ValidationError } from "../core/errors"
import { runSmokeChecks } from "./smoke-checks"
import { rollbackGuidance } from "./rollback"

export async function runDeploy(
  rootDir: string,
  config: DeployConfig,
  options: DeployOptions
): Promise<DeployRunResult> {
  const logger = createLogger(options)
  const startedAt = new Date()
  const runId = createRunId(startedAt)
  const controller = createAbortController()
  const runner = new ExecaProcessRunner(rootDir, options.dryRun, controller.signal)
  const supabase = new SupabaseProvider(rootDir, config, runner)
  const railway = new RailwayProvider(rootDir, config, runner)
  const selected = resolveTargets(config, options.targets, options.all)
  const expanded = selected.flatMap((target) => expandTarget(config, target))
  const results: TargetResult[] = []

  if (options.dryRun) {
    for (const target of expanded) {
      results.push(
        finishTarget(baseResult(target.id), "success", { rollback: rollbackGuidance(target) })
      )
    }
    return writeAndReturn(rootDir, {
      runId,
      env: options.env,
      dryRun: true,
      startedAt: startedAt.toISOString(),
      finishedAt: new Date().toISOString(),
      targets: results,
      smoke: [],
    })
  }

  if (expanded.some((target) => target.kind.startsWith("supabase"))) {
    await supabase.preflight()
    supabase.validateFunctionDrift()
    supabase.resolveProjectRef(options.env)
  }
  if (expanded.some((target) => target.kind.startsWith("railway"))) {
    await railway.preflight()
  }

  for (const target of expanded) {
    const result = baseResult(target.id)
    const commandStart = runner.records.length
    try {
      await deployTarget(target, options, supabase, railway)
      results.push(
        finishTarget(result, "success", {
          commands: runner.records.slice(commandStart),
          rollback: rollbackGuidance(target),
        })
      )
      logger.success(`${target.id} deployed`)
    } catch (error) {
      results.push(
        finishTarget(result, "failed", {
          commands: runner.records.slice(commandStart),
          error: messageFor(error),
          rollback: rollbackGuidance(target),
        })
      )
      logger.warn(`${target.id} failed: ${messageFor(error)}`)
    }
  }

  let smoke: SmokeResult[] = []
  if (options.smoke || process.env.DEPLOY_SMOKE === "1") {
    try {
      smoke = await runSmokeChecks(config, supabase)
    } catch (error) {
      if (error instanceof SmokeError) {
        smoke = await runSmokeChecks(config, supabase).catch(() => [])
      } else {
        throw error
      }
    }
  }

  const result = writeAndReturn(rootDir, {
    runId,
    env: options.env,
    dryRun: false,
    startedAt: startedAt.toISOString(),
    finishedAt: new Date().toISOString(),
    targets: results,
    smoke,
  })

  if (results.some((target) => target.status === "failed")) {
    throw new ValidationError(
      `Deploy finished with ${results.filter((target) => target.status === "failed").length} failure(s)`
    )
  }
  if (smoke.some((item) => item.status === "failed")) {
    throw new SmokeError("Deploy succeeded but smoke checks failed")
  }
  return result
}

async function deployTarget(
  target: DeployTarget,
  options: DeployOptions,
  supabase: SupabaseProvider,
  railway: RailwayProvider
): Promise<void> {
  switch (target.kind) {
    case "supabase:migrations":
      await supabase.deployMigrations()
      return
    case "supabase:function":
      if (!target.name) throw new ValidationError(`Missing function name for target ${target.id}`)
      await supabase.deployFunction(target.name, options.env)
      return
    case "railway:service":
      if (!target.name) throw new ValidationError(`Missing service name for target ${target.id}`)
      await railway.deployService(target.name, {
        poll: options.poll,
        pollTimeoutSeconds: options.pollTimeoutSeconds,
        noPollSuccess: !options.poll,
      })
      return
    case "supabase:functions:all":
    case "railway:all":
      throw new ValidationError(`Unexpected unexpanded target: ${target.id}`)
  }
}

function baseResult(targetId: string): TargetResult {
  const now = new Date().toISOString()
  return {
    targetId,
    status: "skipped",
    startedAt: now,
    finishedAt: now,
    commands: [],
  }
}

function writeAndReturn(rootDir: string, result: DeployRunResult): DeployRunResult {
  const artifactPath = writeRunArtifact(rootDir, result)
  return { ...result, artifactPath }
}
