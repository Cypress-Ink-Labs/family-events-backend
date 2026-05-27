import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"
import { redactObject } from "./redaction"
import type { DeployRunResult } from "./types"

export function createRunId(date = new Date()): string {
  const timestamp = date
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z")
  const random = Math.random().toString(36).slice(2, 8)
  return `${timestamp}-${random}`
}

export function writeRunArtifact(rootDir: string, result: DeployRunResult): string {
  const dir = path.join(rootDir, ".deploy", "runs")
  mkdirSync(dir, { recursive: true })
  const artifactPath = path.join(dir, `${result.runId}.json`)
  writeFileSync(artifactPath, `${JSON.stringify(redactObject(result), null, 2)}\n`)
  return artifactPath
}

export function readRunArtifact(rootDir: string, runId: string): DeployRunResult {
  const artifactPath = path.join(rootDir, ".deploy", "runs", `${runId}.json`)
  return JSON.parse(readFileSync(artifactPath, "utf8")) as DeployRunResult
}
