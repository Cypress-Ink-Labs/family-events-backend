import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import path from "node:path"
import test from "node:test"

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..")
const sharedRunnerPath = path.join(repoRoot, "cron", "_shared", "cron-runner.sh")
const cronServices = Object.entries(
  JSON.parse(
    readFileSync(path.join(repoRoot, "infra", "railway-cron-drift", "cron-services.json"), "utf8")
  )
).map(([name, service]) => ({
  name,
  rootDirectory: service.root_directory,
}))

test("Railway cron services use the shared runner contract", () => {
  const sharedRunner = readFileSync(sharedRunnerPath, "utf8")
  for (const required of ["X-Cron-Run-Key", "X-Cron-Label", "run_key", "runner_log"]) {
    assert.match(sharedRunner, new RegExp(required))
  }
  for (const service of cronServices) {
    const runnerPath = path.join(repoRoot, service.rootDirectory, "cron-runner.sh")
    assert.equal(readFileSync(runnerPath, "utf8"), sharedRunner, `${service.name} runner drifted`)
  }
})

test("Railway cron runner fails hard for broken cron execution", () => {
  const sharedRunner = readFileSync(sharedRunnerPath, "utf8")
  assert.match(sharedRunner, /LOG_CRON_RUN_URL not set/)
  assert.match(sharedRunner, /IS_CRON_ENABLED_URL not set/)
  assert.match(sharedRunner, /cron enabled check failed/)
  assert.match(sharedRunner, /non-2xx response/)
  assert.match(sharedRunner, /exit "\$EXIT_CODE"/)
  assert.doesNotMatch(sharedRunner, /Always exits 0/)
})

test("sync script includes every Railway cron service", () => {
  const script = readFileSync(path.join(repoRoot, "scripts", "sync-cron-runner.sh"), "utf8")
  assert.match(script, /cron\/_shared\/cron-runner\.sh/)
  for (const service of cronServices) {
    assert.match(script, new RegExp(`\\b${service.rootDirectory}\\b`))
  }
})

test("deploy CLI uploads from repo root for rootDirectory-based cron services", () => {
  const wrapper = readFileSync(path.join(repoRoot, "scripts", "deploy.sh"), "utf8")
  const railwayProvider = readFileSync(
    path.join(repoRoot, "packages", "deploy-cli", "src", "providers", "railway.ts"),
    "utf8"
  )
  assert.doesNotMatch(
    wrapper + railwayProvider,
    /railway up "\$ROOT_DIR\/apps\/\$subdir" --path-as-root/
  )
  assert.match(railwayProvider, /"up", "--service", name, "--detach"/)
  assert.match(railwayProvider, /"service", "status", "--service", name, "--json"/)
})
