#!/usr/bin/env node
import { execFileSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const manifestRelativePath = "infra/spacelift-railway-cron-poc/cron-services.json"

function loadServiceConfigs(repoRoot) {
  const manifest = JSON.parse(readFileSync(path.join(repoRoot, manifestRelativePath), "utf8"))
  return Object.entries(manifest).map(([name, value]) => ({
    name,
    configPath: value.config_path,
    sourceRepo: value.source_repo,
    rootDirectory: value.root_directory,
    requiredLatestDeploymentStatus: normalizeStatus(value.required_latest_deployment_status),
    forbiddenInstanceStatuses: (value.forbidden_instance_statuses ?? []).map(normalizeStatus),
  }))
}

const secretKeyPattern = /(secret|token|key|password|credential|authorization|database_url)/i

export function parseRailwayToml(text) {
  const result = {}
  let section = result

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith("#")) {
      continue
    }

    const sectionMatch = line.match(/^\[([^\]]+)\]$/)
    if (sectionMatch) {
      const sectionName = sectionMatch[1]
      result[sectionName] ??= {}
      section = result[sectionName]
      continue
    }

    const valueMatch = line.match(/^([A-Za-z0-9_-]+)\s*=\s*(.+)$/)
    if (!valueMatch) {
      continue
    }

    const [, key, rawValue] = valueMatch
    section[key] = parseTomlScalar(stripInlineTomlComment(rawValue))
  }

  return result
}

function stripInlineTomlComment(rawValue) {
  let inString = false
  let escaped = false

  for (let index = 0; index < rawValue.length; index += 1) {
    const char = rawValue[index]

    if (escaped) {
      escaped = false
      continue
    }

    if (char === "\\") {
      escaped = inString
      continue
    }

    if (char === '"') {
      inString = !inString
      continue
    }

    if (char === "#" && !inString) {
      return rawValue.slice(0, index).trim()
    }
  }

  return rawValue.trim()
}

function parseTomlScalar(rawValue) {
  const value = rawValue.trim()
  const quoted = value.match(/^"([\s\S]*)"$/)
  if (quoted) {
    return quoted[1]
  }
  if (value === "true") {
    return true
  }
  if (value === "false") {
    return false
  }
  if (/^-?\d+(\.\d+)?$/.test(value)) {
    return Number(value)
  }
  return value
}

export function readExpectedCronConfigs(repoRoot = process.cwd()) {
  return loadServiceConfigs(repoRoot).map((service) => {
    const configFile = path.join(repoRoot, service.configPath)
    if (!existsSync(configFile)) {
      throw new Error(`Missing Railway config: ${service.configPath}`)
    }

    const parsed = parseRailwayToml(readFileSync(configFile, "utf8"))
    const deploy = parsed.deploy ?? {}

    return {
      ...service,
      builder: normalizeStatus(deploy.builder ?? parsed.build?.builder ?? ""),
      dockerfilePath: String(parsed.build?.dockerfilePath ?? ""),
      cronSchedule: String(deploy.cronSchedule ?? ""),
      restartPolicyType: normalizeRestartPolicy(deploy.restartPolicyType ?? ""),
    }
  })
}

export function collectRailwayServiceState(serviceName, sources) {
  const sourceObjects = Array.isArray(sources) ? sources : [sources]
  const serviceObjects = sourceObjects.flatMap((source) => findServiceObjects(source, serviceName))
  const searchRoots = serviceObjects.length > 0 ? serviceObjects : sourceObjects

  return {
    cronSchedule:
      findFirstStringByPath(searchRoots, [
        ["cronSchedule"],
        ["serviceManifest", "deploy", "cronSchedule"],
        ["latestDeployment", "meta", "serviceManifest", "deploy", "cronSchedule"],
        ["latestDeployment", "meta", "fileServiceManifest", "deploy", "cronSchedule"],
      ]) ?? findFirstStringByKey(searchRoots, ["cronSchedule", "cron_schedule", "schedule"]),
    restartPolicyType: normalizeRestartPolicy(
      findFirstStringByPath(searchRoots, [
        ["latestDeployment", "meta", "fileServiceManifest", "deploy", "restartPolicyType"],
        ["latestDeployment", "meta", "serviceManifest", "deploy", "restartPolicyType"],
        ["serviceManifest", "deploy", "restartPolicyType"],
        ["restartPolicyType"],
      ]) ??
        findFirstStringByKey(searchRoots, [
          "restartPolicyType",
          "restart_policy_type",
          "restartPolicy",
        ]) ??
        ""
    ),
    sourceRepo:
      findFirstStringByPath(searchRoots, [["source", "repo"], ["latestDeployment", "meta", "repo"]]) ??
      findFirstStringByKey(searchRoots, ["repo"]) ??
      "",
    rootDirectory:
      findFirstStringByPath(searchRoots, [["latestDeployment", "meta", "rootDirectory"]]) ??
      findFirstStringByKey(searchRoots, ["rootDirectory", "root_directory"]) ??
      "",
    builder: normalizeStatus(
      findFirstStringByPath(searchRoots, [
        ["latestDeployment", "meta", "fileServiceManifest", "build", "builder"],
        ["latestDeployment", "meta", "serviceManifest", "build", "builder"],
        ["serviceManifest", "build", "builder"],
      ]) ??
        findFirstStringByKey(searchRoots, ["builder"]) ??
        ""
    ),
    dockerfilePath:
      findFirstStringByPath(searchRoots, [
        ["latestDeployment", "meta", "fileServiceManifest", "build", "dockerfilePath"],
        ["latestDeployment", "meta", "serviceManifest", "build", "dockerfilePath"],
        ["serviceManifest", "build", "dockerfilePath"],
      ]) ??
      findFirstStringByKey(searchRoots, ["dockerfilePath", "dockerfile_path"]) ??
      "",
    latestDeploymentStatus: normalizeStatus(
      findFirstStringByPath(searchRoots, [["latestDeployment", "status"]]) ??
        findFirstStringByKey(searchRoots, ["latestDeploymentStatus", "deploymentStatus", "status"]) ??
        ""
    ),
    instanceStatuses: findStringsByPath(searchRoots, [
      ["latestDeployment", "instances", "*", "status"],
      ["instances", "*", "status"],
    ]).map(normalizeStatus),
  }
}

function findServiceObjects(value, serviceName) {
  const matches = []
  walk(value, (node) => {
    if (!node || typeof node !== "object" || Array.isArray(node)) {
      return
    }
    const names = [node.name, node.serviceName, node.service_name].filter((name) => {
      return typeof name === "string"
    })
    if (names.some((name) => name === serviceName || name.startsWith(`${serviceName}-`))) {
      matches.push(node)
    }
  })
  return matches
}

function findFirstStringByPath(values, paths) {
  for (const value of values) {
    for (const pathParts of paths) {
      const found = getPath(value, pathParts)
      if (typeof found === "string") {
        return found
      }
    }
  }
  return undefined
}

function getPath(value, pathParts) {
  let current = value
  for (const part of pathParts) {
    if (!current || typeof current !== "object" || Array.isArray(current)) {
      return undefined
    }
    if (secretKeyPattern.test(part)) {
      return undefined
    }
    current = current[part]
  }
  return current
}

function findStringsByPath(values, paths) {
  const results = []
  for (const value of values) {
    for (const pathParts of paths) {
      for (const found of getPathMatches(value, pathParts)) {
        if (typeof found === "string") {
          results.push(found)
        }
      }
    }
  }
  return results
}

function getPathMatches(value, pathParts) {
  if (pathParts.length === 0) {
    return [value]
  }

  const [part, ...rest] = pathParts
  if (!value || typeof value !== "object") {
    return []
  }

  if (part === "*") {
    const children = Array.isArray(value) ? value : Object.values(value)
    return children.flatMap((child) => getPathMatches(child, rest))
  }

  if (Array.isArray(value) || secretKeyPattern.test(part)) {
    return []
  }

  return getPathMatches(value[part], rest)
}

function findFirstStringByKey(values, keys) {
  const wanted = new Set(keys.map((key) => key.toLowerCase()))
  let found

  for (const value of values) {
    walk(value, (node, key) => {
      if (found !== undefined || typeof node !== "string" || !key) {
        return
      }
      if (wanted.has(key.toLowerCase())) {
        found = node
      }
    })
    if (found !== undefined) {
      return found
    }
  }

  return undefined
}

function walk(value, visit, key = undefined) {
  visit(value, key)
  if (!value || typeof value !== "object") {
    return
  }

  if (Array.isArray(value)) {
    value.forEach((item) => walk(item, visit, key))
    return
  }

  for (const [childKey, childValue] of Object.entries(value)) {
    if (secretKeyPattern.test(childKey)) {
      continue
    }
    walk(childValue, visit, childKey)
  }
}

export function validateRailwayCronState(expectedConfigs, liveSources) {
  const diagnostics = []

  for (const expected of expectedConfigs) {
    const live = collectRailwayServiceState(expected.name, liveSources)

    if (!live.cronSchedule) {
      diagnostics.push(formatMissing(expected, "cronSchedule"))
      continue
    }
    if (!live.restartPolicyType) {
      diagnostics.push(formatMissing(expected, "restartPolicyType"))
      continue
    }
    if (!live.sourceRepo) {
      diagnostics.push(formatMissing(expected, "sourceRepo"))
      continue
    }
    if (!live.rootDirectory) {
      diagnostics.push(formatMissing(expected, "rootDirectory"))
      continue
    }
    if (!live.builder) {
      diagnostics.push(formatMissing(expected, "builder"))
      continue
    }
    if (!live.dockerfilePath) {
      diagnostics.push(formatMissing(expected, "dockerfilePath"))
      continue
    }
    if (!live.latestDeploymentStatus) {
      diagnostics.push(formatMissing(expected, "requiredLatestDeploymentStatus"))
      continue
    }
    if (live.cronSchedule !== expected.cronSchedule) {
      diagnostics.push(
        `${expected.name}: cronSchedule mismatch: expected "${expected.cronSchedule}" from ${expected.configPath}, live "${live.cronSchedule}"`
      )
    }
    if (live.sourceRepo !== expected.sourceRepo) {
      diagnostics.push(
        `${expected.name}: source repo mismatch: expected "${expected.sourceRepo}" from manifest, live "${live.sourceRepo}"`
      )
    }
    if (live.rootDirectory !== expected.rootDirectory) {
      diagnostics.push(
        `${expected.name}: rootDirectory mismatch: expected "${expected.rootDirectory}" from manifest, live "${live.rootDirectory}"`
      )
    }
    if (live.builder !== expected.builder) {
      diagnostics.push(
        `${expected.name}: build.builder mismatch: expected "${expected.builder}" from ${expected.configPath}, live "${live.builder}"`
      )
    }
    if (live.dockerfilePath !== expected.dockerfilePath) {
      diagnostics.push(
        `${expected.name}: build.dockerfilePath mismatch: expected "${expected.dockerfilePath}" from ${expected.configPath}, live "${live.dockerfilePath}"`
      )
    }
    if (live.restartPolicyType !== expected.restartPolicyType) {
      diagnostics.push(
        `${expected.name}: restartPolicyType mismatch: expected "${expected.restartPolicyType}" from ${expected.configPath}, live "${live.restartPolicyType}"`
      )
    }
    if (live.latestDeploymentStatus !== expected.requiredLatestDeploymentStatus) {
      diagnostics.push(
        `${expected.name}: latestDeployment.status mismatch: expected "${expected.requiredLatestDeploymentStatus}", live "${live.latestDeploymentStatus}"`
      )
    }

    const forbiddenStatuses = live.instanceStatuses.filter((status) => {
      return expected.forbiddenInstanceStatuses.includes(status)
    })
    if (forbiddenStatuses.length > 0) {
      diagnostics.push(
        `${expected.name}: latestDeployment.instances include forbidden statuses ${forbiddenStatuses.join(", ")}`
      )
    }
  }

  return {
    ok: diagnostics.length === 0,
    diagnostics,
  }
}

function formatMissing(expected, field) {
  return `${expected.name}: live Railway metadata missing ${field}; expected "${expected[field]}" from ${expected.configPath}`
}

function normalizeRestartPolicy(value) {
  return String(value).trim().toUpperCase()
}

function normalizeStatus(value) {
  return String(value).trim().toUpperCase()
}

function runRailwayJson(args, cwd) {
  try {
    const output = execFileSync("railway", args, {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    })
    return JSON.parse(output)
  } catch (error) {
    const stderr = String(error.stderr ?? error.message ?? "")
      .split(/\r?\n/)
      .filter((line) => line.trim() && !secretKeyPattern.test(line))
      .slice(0, 4)
      .join("\n")
    const authHint = args[0] === "status" ? "\nRun `railway login` and retry if auth expired." : ""
    throw new Error(
      `Railway CLI JSON command failed: railway ${args.join(" ")}\n${stderr}${authHint}`
    )
  }
}

function loadLiveSources({ repoRoot, fixturePath }) {
  if (fixturePath) {
    return [JSON.parse(readFileSync(path.resolve(repoRoot, fixturePath), "utf8"))]
  }

  const status = runRailwayJson(["status", "--json"], repoRoot)
  const services = runRailwayJson(["service", "list", "--json"], repoRoot)

  return [status, services]
}

function parseArgs(argv) {
  const args = {
    command: argv[2] ?? "validate",
    fixturePath: process.env.SPACELIFT_POC_FIXTURE,
  }

  for (let index = 3; index < argv.length; index += 1) {
    if (argv[index] === "--fixture") {
      args.fixturePath = argv[index + 1]
      index += 1
    }
  }

  return args
}

function main() {
  try {
    const args = parseArgs(process.argv)
    if (args.command !== "validate") {
      console.error("Usage: node scripts/spacelift-railway-cron-poc.mjs validate [--fixture path]")
      process.exitCode = 2
      return
    }

    const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
    const expected = readExpectedCronConfigs(repoRoot)
    const liveSources = loadLiveSources({ repoRoot, fixturePath: args.fixturePath })
    const result = validateRailwayCronState(expected, liveSources)

    if (!result.ok) {
      console.error(result.diagnostics.join("\n"))
      process.exitCode = 1
      return
    }

    for (const service of expected) {
      console.log(
        `${service.name}: ok cronSchedule="${service.cronSchedule}" restartPolicyType="${service.restartPolicyType}" latestDeployment.status="${service.requiredLatestDeploymentStatus}"`
      )
    }
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main()
}
