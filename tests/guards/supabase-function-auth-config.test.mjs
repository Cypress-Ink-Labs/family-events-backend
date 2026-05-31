import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function functionBlock(configToml, functionName) {
  const pattern = new RegExp(
    String.raw`(?:^|\n)\[functions\.${escapeRegExp(functionName)}\]\n([\s\S]*?)(?=\n\[|$)`
  )
  return configToml.match(pattern)?.[1] ?? null
}

test("Supabase no-verify function list is mirrored in config.toml", async () => {
  const [deployConfigJson, configToml] = await Promise.all([
    readFile(new URL("../../config/deploy.config.json", import.meta.url), "utf8"),
    readFile(new URL("../../supabase/config.toml", import.meta.url), "utf8"),
  ])
  const deployConfig = JSON.parse(deployConfigJson)

  const missing = deployConfig.supabase.noVerifyJwtFunctions.filter((functionName) => {
    const block = functionBlock(configToml, functionName)
    return !block || !/\bverify_jwt\s*=\s*false\b/.test(block)
  })

  assert.deepEqual(
    missing,
    [],
    `Expected every deploy noVerifyJwtFunction to have [functions.<name>] verify_jwt = false in supabase/config.toml; missing: ${missing.join(", ")}`
  )
})
