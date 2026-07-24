import assert from "node:assert/strict"
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { spawnSync } from "node:child_process"
import test from "node:test"

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..")
const runnerPath = path.join(repoRoot, "cron", "_shared", "cron-runner.sh")
const targetUrl = "https://target.example.test/function"
const enabledUrl = "https://enabled.example.test/rpc/is_cron_enabled"
const logUrl = "https://log.example.test/function"

function runRunner(targetResult) {
  const stubDir = mkdtempSync(path.join(os.tmpdir(), "cron-runner-curl-"))
  const curlPath = path.join(stubDir, "curl")
  writeFileSync(
    curlPath,
    `#!/bin/sh
output_file=""
expect_output_file=0
url=""
for arg in "$@"; do
  if [ "$expect_output_file" -eq 1 ]; then
    output_file="$arg"
    expect_output_file=0
    continue
  fi
  case "$arg" in
    -o) expect_output_file=1 ;;
    http://*|https://*) url="$arg" ;;
  esac
done

case "$url" in
  "$IS_CRON_ENABLED_URL")
    printf 'true' > "$output_file"
    printf '200'
    exit 0
    ;;
  "$LOG_CRON_RUN_URL")
    printf '200'
    exit 0
    ;;
  "$TARGET_URL")
    printf '200'
    if [ "$TARGET_RESULT" = "post-header-failure" ]; then
      exit 28
    fi
    exit 0
    ;;
  *)
    printf 'unexpected curl URL: %s\\n' "$url" >&2
    exit 99
    ;;
esac
`,
    { mode: 0o755 }
  )
  chmodSync(curlPath, 0o755)

  try {
    return spawnSync("sh", [runnerPath, targetUrl, "cron-test"], {
      cwd: repoRoot,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${stubDir}${path.delimiter}${process.env.PATH ?? ""}`,
        IS_CRON_ENABLED_URL: enabledUrl,
        LOG_CRON_RUN_URL: logUrl,
        SUPABASE_SERVICE_ROLE_KEY: "x",
        TARGET_URL: targetUrl,
        TARGET_RESULT: targetResult,
      },
    })
  } finally {
    rmSync(stubDir, { recursive: true, force: true })
  }
}

test("post-header curl failure fails the run and never reports success", () => {
  const result = runRunner("post-header-failure")

  assert.notEqual(result.status, 0, result.stdout)
  assert.match(result.stdout, /"msg":"curl failed \(network\/timeout\)"/)
  assert.doesNotMatch(result.stdout, /"status":"succeeded"/)
})

test("HTTP 200 with successful curl still succeeds", () => {
  const result = runRunner("success")

  assert.equal(result.status, 0, result.stdout)
  assert.match(result.stdout, /"msg":"ok"/)
})
