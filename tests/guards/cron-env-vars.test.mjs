import assert from "node:assert/strict"
import { readdirSync, readFileSync } from "node:fs"
import path from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

// Repo-only guard (no Railway access): keep each cron's target URL var wired across
// the three places that must agree, so a new cron can't ship missing its URL — the
// failure that crashed cron-weekly-digest (empty SEND_WEEKLY_DIGEST_URL).
//   1. cron/<dir>/Dockerfile ENTRYPOINT passes "$<FN>_URL" to cron-runner.sh
//   2. infra/railway-cron-drift/cron-services.json lists it in required_env
//   3. .railway/railway.ts SETS it (fnUrl/rpcUrl), not preserve()

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..")
const manifest = JSON.parse(
  readFileSync(path.join(repoRoot, "infra", "railway-cron-drift", "cron-services.json"), "utf8")
)
const iac = readFileSync(path.join(repoRoot, ".railway", "railway.ts"), "utf8")

const SHARED_REQUIRED = ["SUPABASE_SERVICE_ROLE_KEY", "IS_CRON_ENABLED_URL", "LOG_CRON_RUN_URL"]

/** Extract the `$<NAME>_URL` the Dockerfile ENTRYPOINT passes as cron-runner.sh's first arg. */
function dockerfileUrlVar(rootDirectory) {
  const text = readFileSync(path.join(repoRoot, rootDirectory, "Dockerfile"), "utf8")
  const match = text.match(/cron-runner\.sh\s+\\?"\$([A-Z0-9_]+_URL)\\?"/)
  assert.ok(
    match,
    `${rootDirectory}/Dockerfile ENTRYPOINT does not pass a $*_URL to cron-runner.sh`
  )
  return match[1]
}

test("every cron/<dir> has a cron-services.json entry (and vice versa)", () => {
  const cronDirs = readdirSync(path.join(repoRoot, "cron"), { withFileTypes: true })
    .filter((e) => e.isDirectory() && e.name !== "_shared")
    .map((e) => `cron/${e.name}`)
    .sort()
  const manifestDirs = Object.values(manifest)
    .map((s) => s.root_directory)
    .sort()
  assert.deepEqual(manifestDirs, cronDirs, "cron-services.json root_directory set != cron/* dirs")
})

test("each cron's Dockerfile URL var is required_env + SET in the Railway IaC", () => {
  for (const [name, service] of Object.entries(manifest)) {
    const urlVar = dockerfileUrlVar(service.root_directory)
    const required = service.required_env ?? []

    // (2) listed in required_env, alongside the shared keys
    assert.ok(
      required.includes(urlVar),
      `${name}: ${urlVar} (from Dockerfile) is missing from required_env`
    )
    for (const shared of SHARED_REQUIRED) {
      assert.ok(required.includes(shared), `${name}: required_env is missing shared key ${shared}`)
    }

    // (3) SET in .railway/railway.ts via fnUrl()/rpcUrl(), never preserve()
    assert.match(
      iac,
      new RegExp(`${urlVar}\\s*:\\s*(fnUrl|rpcUrl)\\(`),
      `${name}: ${urlVar} is not SET (fnUrl/rpcUrl) in .railway/railway.ts`
    )
    assert.doesNotMatch(
      iac,
      new RegExp(`${urlVar}\\s*:\\s*preserve\\(`),
      `${name}: ${urlVar} must be SET, not preserve(), in .railway/railway.ts`
    )
  }
})
