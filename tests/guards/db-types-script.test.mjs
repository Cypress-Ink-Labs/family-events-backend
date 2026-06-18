import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");

function readPackageScripts() {
  return JSON.parse(readFileSync(path.join(repoRoot, "package.json"), "utf8")).scripts;
}

function readSupabaseDbPort() {
  const config = readFileSync(path.join(repoRoot, "supabase", "config.toml"), "utf8");
  const dbBlock = /\[db\]([\s\S]*?)(?:\n\[|$)/.exec(config)?.[1];
  assert.ok(dbBlock, "supabase/config.toml is missing a [db] block");
  const port = /^port\s*=\s*(\d+)$/m.exec(dbBlock)?.[1];
  assert.ok(port, "supabase/config.toml [db] block is missing port");
  return port;
}

function readCiWorkflow() {
  return readFileSync(path.join(repoRoot, ".github", "workflows", "ci.yml"), "utf8");
}

test("db:types uses the configured local Supabase database port", () => {
  const dbTypes = readPackageScripts()["db:types"];
  assert.match(dbTypes, /gen types --lang typescript\b/);
  assert.match(dbTypes, new RegExp("127\\.0\\.0\\.1:" + readSupabaseDbPort() + "/postgres"));
});

test("CI db type drift check uses the configured local Supabase database port", () => {
  const workflow = readCiWorkflow();
  assert.match(workflow, /version: 2\.105\.0/);
  assert.match(workflow, /supabase gen types --lang typescript\b/);
  assert.match(workflow, new RegExp("127\\.0\\.0\\.1:" + readSupabaseDbPort() + "/postgres"));
});
