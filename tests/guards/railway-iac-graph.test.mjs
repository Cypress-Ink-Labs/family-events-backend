import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { readFileSync } from "node:fs"
import path from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

// Repo-only guard (runs OFFLINE — no Railway network/auth): re-run the same IaC
// evaluator that `pnpm run deploy:all` relies on and assert it produces a
// NON-EMPTY desired graph containing every cron service.
//
// CIL-104 regression: deploy:all once computed an EMPTY Railway IaC desiredGraph
// (the deploy-cli logged "IaC runner returned non-JSON output") while 9 prod
// services were live, so the changeSet planned to DELETE every service. The
// runtime safety rail (abort-on-destructive) already shipped in 4706226; this
// guard is the *static* tripwire — if the runner ever emits an empty or
// unparseable graph again, CI fails here BEFORE anyone runs deploy:all.

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..")
const evaluatorPath = path.join(repoRoot, "scripts", "evaluate-railway-iac-graph.mjs")
const railwayConfigPath = path.join(repoRoot, ".railway", "railway.ts")

// Derive the cron service addresses the IaC declares straight from the source of
// truth (.railway/railway.ts), the same file the cron-env-vars guard parses.
// Each cron is declared via `cronService("cron-<name>", ...)`.
function declaredCronServiceAddresses() {
  const iac = readFileSync(railwayConfigPath, "utf8")
  const names = [...iac.matchAll(/cronService\(\s*"([^"]+)"/g)].map((match) => match[1])
  return [...new Set(names)].map((name) => `service.${name}`)
}

function runEvaluator() {
  const result = spawnSync("node", [evaluatorPath, railwayConfigPath], {
    cwd: repoRoot,
    encoding: "utf8",
    // Capture stdout only; the evaluator prints JSON to stdout and any Node
    // warnings to stderr, so JSON.parse must see stdout in isolation.
    stdio: ["ignore", "pipe", "pipe"],
  })
  return result
}

test("evaluate-railway-iac-graph exits 0 with a parseable, ok desired graph", () => {
  const result = runEvaluator()

  assert.equal(result.status, 0, `evaluator exited ${result.status}; stderr:\n${result.stderr}`)

  let parsed
  assert.doesNotThrow(() => {
    parsed = JSON.parse(result.stdout)
  }, `evaluator stdout was not JSON (the "IaC runner returned non-JSON output" failure):\n${result.stdout}`)

  assert.equal(parsed.ok, true, "IaC evaluation reported ok=false")
  assert.deepEqual(parsed.diagnostics, [], "IaC evaluation produced diagnostics")
})

test("desired graph resources are non-empty and include every declared cron service", () => {
  const result = runEvaluator()
  assert.equal(result.status, 0, `evaluator exited ${result.status}; stderr:\n${result.stderr}`)

  const parsed = JSON.parse(result.stdout)
  assert.ok(parsed.graph, "evaluator output is missing the desired graph")
  const resources = parsed.graph.resources

  assert.ok(Array.isArray(resources), "graph.resources is not an array")
  assert.ok(
    resources.length > 0,
    "graph.resources is EMPTY — deploy:all would plan to DELETE every live service (CIL-104)"
  )

  const addresses = new Set(resources.map((resource) => resource?.address))

  // The Cron Jobs group must be present.
  assert.ok(
    addresses.has("group.Cron Jobs"),
    `desired graph is missing the "group.Cron Jobs" resource; got: ${[...addresses].join(", ")}`
  )

  // Every cron service declared in .railway/railway.ts must show up in the graph.
  const expectedCronAddresses = declaredCronServiceAddresses()
  assert.ok(
    expectedCronAddresses.length > 0,
    ".railway/railway.ts declares no cronService(...) entries — parser drift?"
  )
  for (const address of expectedCronAddresses) {
    assert.ok(
      addresses.has(address),
      `desired graph is missing cron service "${address}"; got: ${[...addresses].join(", ")}`
    )
  }
})
