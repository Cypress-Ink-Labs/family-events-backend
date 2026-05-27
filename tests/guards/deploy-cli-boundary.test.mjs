import assert from "node:assert/strict"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import path from "node:path"
import test from "node:test"

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..")

test("root deploy scripts route through the TypeScript deploy CLI", () => {
  const pkg = JSON.parse(readFileSync(path.join(repoRoot, "package.json"), "utf8"))
  assert.equal(pkg.scripts.deploy, "pnpm --filter @family-events/deploy-cli cli")
  assert.equal(pkg.scripts["deploy:all"], "pnpm --filter @family-events/deploy-cli cli deploy --all --yes")

  const wrapper = readFileSync(path.join(repoRoot, "scripts", "deploy.sh"), "utf8")
  assert.match(wrapper, /@family-events\/deploy-cli/)
  assert.match(wrapper, /pnpm --filter/)
})

test("deploy config includes every Supabase function directory", () => {
  const config = JSON.parse(readFileSync(path.join(repoRoot, "config", "deploy.config.json"), "utf8"))
  const configured = [...config.supabase.functions].sort()
  const discovered = readFileSync(path.join(repoRoot, "supabase", "functions", "deno.json"), "utf8")
    ? Array.from(
        new Set(
          readdirSync(path.join(repoRoot, "supabase", "functions"), { withFileTypes: true })
            .filter((entry) => entry.isDirectory())
            .map((entry) => entry.name)
            .filter((name) => name !== "_shared" && existsSync(path.join(repoRoot, "supabase", "functions", name, "index.ts")))
        )
      ).sort()
    : []
  assert.deepEqual(configured, discovered)
})

test("deploy config includes every Railway cron app with railway.toml", () => {
  const config = JSON.parse(readFileSync(path.join(repoRoot, "config", "deploy.config.json"), "utf8"))
  const configured = new Set(config.railway.services.map((service) => service.name))
  assert.equal(configured.has("web"), true)

  const cronApps = readdirSync(path.join(repoRoot, "apps"), { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("cron-"))
    .map((entry) => entry.name)
    .filter((name) => existsSync(path.join(repoRoot, "apps", name, "railway.toml")))

  for (const app of cronApps) {
    assert.equal(configured.has(app), true, `${app} missing from deploy config`)
  }
})
