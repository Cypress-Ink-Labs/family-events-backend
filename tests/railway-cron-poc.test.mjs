import assert from "node:assert/strict"
import test from "node:test"

import {
  collectServiceVariableKeys,
  validateRailwayCronState,
  validateRequiredEnv,
} from "../scripts/railway-cron-drift.mjs"

// ── collectServiceVariableKeys ───────────────────────────────────────────────

test("collectServiceVariableKeys: present (non-empty) keys from a variables object", () => {
  const sources = [{ serviceName: "cron-x", variables: { A_URL: "https://x", EMPTY: "", B: "v" } }]
  const { available, keys } = collectServiceVariableKeys("cron-x", sources)
  assert.equal(available, true)
  assert.ok(keys.has("A_URL"))
  assert.ok(keys.has("B"))
  assert.ok(!keys.has("EMPTY"), "empty-valued vars are not 'present'")
})

test("collectServiceVariableKeys: variableKeys array + startsWith name match", () => {
  const sources = [{ serviceName: "cron-x-abc12", variableKeys: ["A_URL", "C"] }]
  const { available, keys } = collectServiceVariableKeys("cron-x", sources)
  assert.equal(available, true)
  assert.deepEqual([...keys].sort(), ["A_URL", "C"])
})

test("collectServiceVariableKeys: unavailable when no variable info present", () => {
  const { available, keys } = collectServiceVariableKeys("cron-x", [{ serviceName: "cron-x" }])
  assert.equal(available, false)
  assert.equal(keys.size, 0)
})

// ── validateRequiredEnv (pure) ───────────────────────────────────────────────

const expected = [{ name: "cron-x", requiredEnv: ["A_URL", "SUPABASE_SERVICE_ROLE_KEY"] }]

test("validateRequiredEnv: missing required key -> diagnostic", () => {
  const diags = validateRequiredEnv(expected, {
    "cron-x": { available: true, keys: new Set(["A_URL"]) },
  })
  assert.deepEqual(diags, ["cron-x: required env SUPABASE_SERVICE_ROLE_KEY is missing or empty"])
})

test("validateRequiredEnv: all present -> no diagnostics", () => {
  const diags = validateRequiredEnv(expected, {
    "cron-x": { available: true, keys: new Set(["A_URL", "SUPABASE_SERVICE_ROLE_KEY"]) },
  })
  assert.deepEqual(diags, [])
})

test("validateRequiredEnv: unavailable vars -> skipped (no false failure)", () => {
  const diags = validateRequiredEnv(expected, { "cron-x": { available: false, keys: new Set() } })
  assert.deepEqual(diags, [])
})

// ── validateRailwayCronState integration (metadata all matches; only env varies) ─

function makeExpected(overrides = {}) {
  return {
    name: "cron-x",
    configPath: ".railway/railway.ts",
    cronSchedule: "*/5 * * * *",
    restartPolicyType: "NEVER",
    sourceRepo: "Cypress-Ink-Labs/family-events-backend",
    rootDirectory: "cron/x",
    builder: "DOCKERFILE",
    dockerfilePath: "Dockerfile",
    requiredLatestDeploymentStatus: "SUCCESS",
    forbiddenInstanceStatuses: ["CRASHED", "FAILED"],
    requiredEnv: ["A_URL"],
    ...overrides,
  }
}

function makeLiveNode(variables) {
  return {
    serviceName: "cron-x",
    cronSchedule: "*/5 * * * *",
    source: { repo: "Cypress-Ink-Labs/family-events-backend" },
    latestDeployment: {
      status: "SUCCESS",
      instances: [{ status: "RUNNING" }],
      meta: {
        rootDirectory: "cron/x",
        fileServiceManifest: {
          build: { builder: "DOCKERFILE", dockerfilePath: "Dockerfile" },
          deploy: { restartPolicyType: "NEVER" },
        },
      },
    },
    variables,
  }
}

test("validateRailwayCronState: clean when metadata + required env all present", () => {
  const result = validateRailwayCronState([makeExpected()], [makeLiveNode({ A_URL: "https://x" })])
  assert.equal(result.ok, true, result.diagnostics.join("\n"))
})

test("validateRailwayCronState: flags an empty required URL (the cron-weekly-digest failure)", () => {
  const result = validateRailwayCronState([makeExpected()], [makeLiveNode({ A_URL: "" })])
  assert.equal(result.ok, false)
  assert.ok(
    result.diagnostics.includes("cron-x: required env A_URL is missing or empty"),
    result.diagnostics.join("\n")
  )
})
