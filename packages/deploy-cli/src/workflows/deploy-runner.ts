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
import { DeployFailureError, messageFor, SmokeError, ValidationError } from "../core/errors"
import { runSmokeChecks } from "./smoke-checks"
import { rollbackGuidance } from "./rollback"
import { createSpinner } from "../ui/progress"

export async function runDeploy(
  rootDir: string,
  config: DeployConfig,
  options: DeployOptions
): Promise<DeployRunResult> {
  const logger = createLogger(options)
  const startedAt = new Date()
  const runId = createRunId(startedAt)
  const controller = createAbortController()
  const preflightRunner = new ExecaProcessRunner(
    rootDir,
    options.dryRun,
    controller.signal,
    options.showOutput && !options.json
  )
  const supabase = new SupabaseProvider(rootDir, config, preflightRunner)
  const railway = new RailwayProvider(rootDir, config, preflightRunner)
  const selected = resolveTargets(config, options.targets, options.all)
  const expanded = selected.flatMap((target) => expandTarget(config, target))
  const results = new Array<TargetResult>(expanded.length)

  if (options.dryRun) {
    const dryRunResults = expanded.map((target) =>
      finishTarget(baseResult(target.id), "success", { rollback: rollbackGuidance(target) })
    )
    return writeAndReturn(rootDir, {
      runId,
      env: options.env,
      dryRun: true,
      startedAt: startedAt.toISOString(),
      finishedAt: new Date().toISOString(),
      targets: dryRunResults,
      smoke: [],
    })
  }

  if (expanded.some((target) => target.kind.startsWith("supabase"))) {
    const spinner = createSpinner("Checking Supabase deploy prerequisites", useSpinner(options))
    try {
      await supabase.preflight()
      supabase.validateFunctionDrift()
      supabase.resolveProjectRef(options.env)
      spinner?.succeed("Supabase deploy prerequisites ready")
    } catch (error) {
      spinner?.fail("Supabase deploy prerequisites failed")
      throw error
    }
  }
  if (expanded.some((target) => target.kind.startsWith("railway"))) {
    const spinner = createSpinner("Checking Railway deploy prerequisites", useSpinner(options))
    try {
      await railway.preflight()
      spinner?.succeed("Railway deploy prerequisites ready")
    } catch (error) {
      spinner?.fail("Railway deploy prerequisites failed")
      throw error
    }
  }

  expanded.forEach((target, index) => {
    results[index] = baseResult(target.id)
  })

  await deployStage(
    "Supabase migrations",
    indexedTargets(expanded, "supabase:migrations"),
    1,
    rootDir,
    config,
    options,
    controller.signal,
    results,
    logger
  )
  await deployStage(
    "Supabase functions",
    indexedTargets(expanded, "supabase:function"),
    options.functionConcurrency,
    rootDir,
    config,
    options,
    controller.signal,
    results,
    logger
  )
  const railwayTargets = indexedTargets(expanded, "railway:service")
  const railwayIndependent = railwayTargets.filter(
    ({ target }) => !hasSelectedBootstrapDependency(target, railwayTargets, config)
  )
  const railwayDependent = railwayTargets.filter(({ target }) =>
    hasSelectedBootstrapDependency(target, railwayTargets, config)
  )

  await deployStage(
    "Railway services",
    railwayIndependent,
    options.railwayConcurrency,
    rootDir,
    config,
    options,
    controller.signal,
    results,
    logger
  )
  await deployStage(
    "Railway dependent services",
    railwayDependent,
    options.railwayConcurrency,
    rootDir,
    config,
    options,
    controller.signal,
    results,
    logger
  )

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
    targets: compactResults(results),
    smoke,
  })

  if (results.some((target) => target.status === "failed")) {
    throw new DeployFailureError(
      `Deploy finished with ${results.filter((target) => target.status === "failed").length} failure(s)`
    )
  }
  if (smoke.some((item) => item.status === "failed")) {
    throw new SmokeError("Deploy succeeded but smoke checks failed")
  }
  return result
}

async function deployStage(
  label: string,
  targets: IndexedTarget[],
  concurrency: number,
  rootDir: string,
  config: DeployConfig,
  options: DeployOptions,
  signal: AbortSignal,
  results: TargetResult[],
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  if (targets.length === 0) return

  const parallel = concurrency > 1 && targets.length > 1
  const spinner = createSpinner(
    parallel ? `${label}: deploying ${targets.length} targets` : undefined,
    parallel && useSpinner(options)
  )

  await mapLimit(targets, concurrency, async ({ target, index }) => {
    if (options.showOutput || options.verbose || options.debug) {
      logger.info(`deploying ${target.id}`)
    }
    const targetSpinner = createSpinner(`Deploying ${target.id}`, !parallel && useSpinner(options))
    const runner = new ExecaProcessRunner(
      rootDir,
      options.dryRun,
      signal,
      options.showOutput && !options.json
    )
    const supabase = new SupabaseProvider(rootDir, config, runner)
    const railway = new RailwayProvider(rootDir, config, runner)
    const result = baseResult(target.id)

    try {
      await deployTarget(target, options, supabase, railway)
      targetSpinner?.succeed(`${target.id} deployed`)
      results[index] = finishTarget(result, "success", {
        commands: runner.records,
        rollback: rollbackGuidance(target),
      })
      if (!targetSpinner && !parallel) logger.success(`${target.id} deployed`)
    } catch (error) {
      targetSpinner?.fail(`${target.id} failed`)
      results[index] = finishTarget(result, "failed", {
        commands: runner.records,
        error: messageFor(error),
        rollback: rollbackGuidance(target),
      })
      logger.warn(`${target.id} failed: ${messageFor(error)}`)
    }
  })

  const failed = targets.filter(({ index }) => results[index]?.status === "failed").length
  if (failed > 0) {
    spinner?.fail(`${label}: ${failed}/${targets.length} failed`)
  } else {
    spinner?.succeed(`${label}: ${targets.length}/${targets.length} deployed`)
  }
}

type IndexedTarget = { target: DeployTarget; index: number }

function indexedTargets(targets: DeployTarget[], kind: DeployTarget["kind"]): IndexedTarget[] {
  return targets
    .map((target, index) => ({ target, index }))
    .filter(({ target }) => target.kind === kind)
}

function hasSelectedBootstrapDependency(
  target: DeployTarget,
  selected: IndexedTarget[],
  config: DeployConfig
): boolean {
  if (target.kind !== "railway:service" || !target.name) return false
  const service = config.railway.services.find((candidate) => candidate.name === target.name)
  if (!service?.bootstrapFromService) return false
  return selected.some(({ target: candidate }) => candidate.name === service.bootstrapFromService)
}

async function mapLimit<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>
): Promise<void> {
  let cursor = 0
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (cursor < items.length) {
      const item = items[cursor]
      cursor += 1
      if (item) await worker(item)
    }
  })
  await Promise.all(workers)
}

function compactResults(results: TargetResult[]): TargetResult[] {
  return results.filter((result): result is TargetResult => Boolean(result))
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

function useSpinner(options: DeployOptions): boolean {
  return !options.json && !options.showOutput && !options.dryRun
}
