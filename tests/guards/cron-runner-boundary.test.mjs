import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import path from "node:path"
import test from "node:test"

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..")
const sharedRunnerPath = path.join(repoRoot, "apps", "_shared", "cron-runner.sh")
const cronApps = [
  "cron-cleanup-stale",
  "cron-db-maintenance",
  "cron-enrich-events",
  "cron-review-events",
  "cron-scrape-sources",
  "cron-tag-queue",
]

test("Railway cron services use the shared runner contract", () => {
  const sharedRunner = readFileSync(sharedRunnerPath, "utf8")
  for (const app of cronApps) {
    const runnerPath = path.join(repoRoot, "apps", app, "cron-runner.sh")
    assert.equal(readFileSync(runnerPath, "utf8"), sharedRunner, `${app} runner drifted`)
  }
})

test("sync script includes every Railway cron service", () => {
  const script = readFileSync(path.join(repoRoot, "scripts", "sync-cron-runner.sh"), "utf8")
  for (const app of cronApps) {
    assert.match(script, new RegExp(`\\b${app}\\b`))
  }
})
