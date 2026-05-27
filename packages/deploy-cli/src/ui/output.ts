import type { DeployRunResult, DeployTarget, SmokeResult } from "../core/types"

export function printTargets(targets: DeployTarget[], json: boolean): void {
  if (json) {
    console.log(JSON.stringify(targets, null, 2))
    return
  }
  for (const target of targets) {
    console.log(`${target.id}\t${target.label}`)
  }
}

export function printDeployResult(result: DeployRunResult, json: boolean): void {
  if (json) {
    console.log(JSON.stringify(result, null, 2))
    return
  }

  console.log(`run: ${result.runId}`)
  if (result.artifactPath) {
    console.log(`artifact: ${result.artifactPath}`)
  }
  for (const target of result.targets) {
    console.log(`${target.status}\t${target.targetId}`)
    if (target.error) console.log(`  ${target.error}`)
  }
  printSmoke(result.smoke)
}

export function printSmoke(smoke: SmokeResult[]): void {
  for (const result of smoke) {
    console.log(`${result.status}\t${result.name}\t${result.message}`)
  }
}
