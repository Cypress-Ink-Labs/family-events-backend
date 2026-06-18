#!/usr/bin/env node
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import process from "node:process"
import { Sandbox } from "railway"

const DEFAULT_IDLE_TIMEOUT_MINUTES = 30
const DEFAULT_EXEC_TIMEOUT_SEC = 120
const DEFAULT_REPO_TIMEOUT_SEC = 600
const DEFAULT_REPO_COMMAND = "pnpm run workspace:test"

const helpText = [
  "Usage:",
  "  pnpm run railway:sandbox -- list [--json]",
  "  pnpm run railway:sandbox -- create [--private-network] [--idle-timeout-minutes <minutes>] [--json]",
  "  pnpm run railway:sandbox -- destroy <sandbox-id>",
  "  pnpm run railway:sandbox -- exec [--id <sandbox-id>] [--keep] [--private-network] [--idle-timeout-minutes <minutes>] [--timeout-sec <seconds>] -- <command>",
  "  pnpm run railway:sandbox -- repo-check [--ref <git-ref>] [--command <command>] [--keep] [--private-network] [--idle-timeout-minutes <minutes>] [--timeout-sec <seconds>]",
  "",
  "Required for live commands:",
  "  RAILWAY_API_TOKEN or RAILWAY_TOKEN",
  "  RAILWAY_ENVIRONMENT_ID",
  "",
  "Optional for private GitHub repos in repo-check:",
  "  RAILWAY_SANDBOX_GITHUB_TOKEN or GITHUB_TOKEN or GH_TOKEN",
  "",
  "Notes:",
  "  - Sandboxes are ephemeral Railway VMs scoped to the selected environment.",
  "  - exec without --id creates a sandbox, runs the command, and destroys it unless --keep is set.",
  "  - repo-check clones the current GitHub repo, installs the mise-pinned toolchain, runs pnpm install, then runs the requested command.",
  "",
].join("\n")

class UsageError extends Error {}

function readValue(args, index, flag) {
  const value = args[index + 1]
  if (!value || value.startsWith("--")) {
    throw new UsageError(flag + " requires a value")
  }
  return value
}

function parsePositiveInteger(value, flag) {
  if (!/^\d+$/.test(value)) {
    throw new UsageError(flag + " must be a positive integer")
  }

  const parsed = Number(value)
  if (parsed < 1) {
    throw new UsageError(flag + " must be greater than 0")
  }

  return parsed
}

export function parseArgs(argv) {
  const [command = "help", ...args] = argv
  const options = {
    command: command === "--help" || command === "-h" ? "help" : command,
    commandArgs: [],
    idleTimeoutMinutes: DEFAULT_IDLE_TIMEOUT_MINUTES,
    json: false,
    keep: false,
    networkIsolation: "ISOLATED",
    ref: undefined,
    sandboxId: undefined,
    timeoutSec: command === "repo-check" ? DEFAULT_REPO_TIMEOUT_SEC : DEFAULT_EXEC_TIMEOUT_SEC,
  }

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]

    if (arg === "--") {
      options.commandArgs = args.slice(index + 1)
      break
    }

    if (arg === "--help" || arg === "-h") {
      options.command = "help"
      continue
    }

    if (arg === "--json") {
      options.json = true
      continue
    }

    if (arg === "--keep") {
      options.keep = true
      continue
    }

    if (arg === "--private-network") {
      options.networkIsolation = "PRIVATE"
      continue
    }

    if (arg === "--id") {
      options.sandboxId = readValue(args, index, arg)
      index += 1
      continue
    }

    if (arg === "--ref") {
      options.ref = readValue(args, index, arg)
      index += 1
      continue
    }

    if (arg === "--command") {
      options.commandArgs = [readValue(args, index, arg)]
      index += 1
      continue
    }

    if (arg === "--idle-timeout-minutes") {
      options.idleTimeoutMinutes = parsePositiveInteger(readValue(args, index, arg), arg)
      index += 1
      continue
    }

    if (arg === "--timeout-sec") {
      options.timeoutSec = parsePositiveInteger(readValue(args, index, arg), arg)
      index += 1
      continue
    }

    if (command === "destroy" && !options.sandboxId) {
      options.sandboxId = arg
      continue
    }

    throw new UsageError("Unknown option: " + arg)
  }

  return options
}

function requireRailwayEnvironment() {
  const missing = []
  if (!process.env.RAILWAY_API_TOKEN && !process.env.RAILWAY_TOKEN) {
    missing.push("RAILWAY_API_TOKEN or RAILWAY_TOKEN")
  }

  if (!process.env.RAILWAY_ENVIRONMENT_ID) {
    missing.push("RAILWAY_ENVIRONMENT_ID")
  }

  if (missing.length > 0) {
    throw new UsageError("Missing required environment variable(s): " + missing.join(", "))
  }
}

function railwayClientOptions() {
  return {
    token: process.env.RAILWAY_API_TOKEN ?? process.env.RAILWAY_TOKEN,
    environmentId: process.env.RAILWAY_ENVIRONMENT_ID,
  }
}

export function normalizeGitHubRepoSlug(remoteUrl) {
  const trimmed = remoteUrl.trim()
  const sshMatch = /^git@github\.com:([^/]+\/[^/]+?)(?:\.git)?$/.exec(trimmed)
  if (sshMatch) {
    return sshMatch[1]
  }

  const httpsMatch = /^https:\/\/github\.com\/([^/]+\/[^/]+?)(?:\.git)?$/.exec(trimmed)
  if (httpsMatch) {
    return httpsMatch[1]
  }

  throw new UsageError("repo-check only supports GitHub remotes, got: " + remoteUrl)
}

function currentGitRemoteUrl() {
  return execFileSync("git", ["config", "--get", "remote.origin.url"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim()
}

function currentGitRef() {
  return execFileSync("git", ["rev-parse", "HEAD"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim()
}

function shellQuote(value) {
  return "'" + String(value).replaceAll("'", "'\\''") + "'"
}

export function buildRepoCheckCommand({ repoSlug, ref, command = DEFAULT_REPO_COMMAND }) {
  return [
    "set -eu",
    "export DEBIAN_FRONTEND=noninteractive",
    "apt-get update",
    "apt-get install -y ca-certificates curl git xz-utils",
    'if [ -n "${GITHUB_TOKEN:-}" ]; then',
    '  git clone "https://x-access-token:$GITHUB_TOKEN@github.com/' +
      repoSlug +
      '.git" family-events',
    "else",
    '  git clone "https://github.com/' + repoSlug + '.git" family-events',
    "fi",
    "cd family-events",
    "git checkout " + shellQuote(ref),
    "curl https://mise.run | sh",
    'export PATH="$HOME/.local/bin:$PATH"',
    "mise trust --yes mise.toml",
    "mise install",
    "corepack enable",
    "pnpm install --frozen-lockfile",
    command,
  ].join("\n")
}

export function resolveRepoCheckCommand(commandArgs) {
  if (commandArgs.length === 0) {
    return DEFAULT_REPO_COMMAND
  }

  if (commandArgs[0] === "--command") {
    const command = commandArgs.slice(1).join(" ").trim()
    if (!command) {
      throw new UsageError("--command requires a value")
    }

    return command
  }

  return commandArgs.join(" ").trim()
}

function sandboxCreateOptions(options, env = {}) {
  return {
    ...railwayClientOptions(),
    idleTimeoutMinutes: options.idleTimeoutMinutes,
    networkIsolation: options.networkIsolation,
    env,
  }
}

function githubTokenEnv() {
  const token =
    process.env.RAILWAY_SANDBOX_GITHUB_TOKEN ?? process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN

  return token ? { GITHUB_TOKEN: token } : {}
}

function printJson(value) {
  process.stdout.write(JSON.stringify(value, null, 2) + "\n")
}

function printSandbox(sandbox) {
  process.stdout.write(
    [
      "id=" + sandbox.id,
      "status=" + sandbox.status,
      "networkIsolation=" + sandbox.networkIsolation,
      "idleTimeoutMinutes=" + sandbox.idleTimeoutMinutes,
      "region=" + sandbox.region,
    ].join(" ") + "\n"
  )
}

async function listSandboxes(options) {
  requireRailwayEnvironment()
  const sandboxes = await Sandbox.list(railwayClientOptions())
  if (options.json) {
    printJson(sandboxes)
    return
  }

  if (sandboxes.length === 0) {
    process.stdout.write("No sandboxes found.\n")
    return
  }

  for (const sandbox of sandboxes) {
    process.stdout.write(
      [
        sandbox.id,
        sandbox.status,
        sandbox.networkIsolation,
        sandbox.idleTimeoutMinutes ?? "default",
        sandbox.region,
        sandbox.createdAt,
      ].join("\t") + "\n"
    )
  }
}

async function createSandbox(options) {
  requireRailwayEnvironment()
  const sandbox = await Sandbox.create(sandboxCreateOptions(options))
  if (options.json) {
    printJson(sandbox.toJSON())
    return
  }

  printSandbox(sandbox)
}

async function destroySandbox(options) {
  requireRailwayEnvironment()
  if (!options.sandboxId) {
    throw new UsageError("destroy requires a sandbox id")
  }

  const sandbox = await Sandbox.connect(options.sandboxId, railwayClientOptions())
  await sandbox.destroy()
  process.stdout.write("Destroyed sandbox " + options.sandboxId + ".\n")
}

async function runExec(options) {
  requireRailwayEnvironment()
  const command = options.commandArgs.join(" ").trim()
  if (!command) {
    throw new UsageError("exec requires a command after --")
  }

  let sandbox
  let created = false
  if (options.sandboxId) {
    sandbox = await Sandbox.connect(options.sandboxId, railwayClientOptions())
  } else {
    sandbox = await Sandbox.create(sandboxCreateOptions(options))
    created = true
    printSandbox(sandbox)
  }

  try {
    const result = await sandbox.exec(command, {
      timeoutSec: options.timeoutSec,
      onStdout: (chunk) => process.stdout.write(chunk),
      onStderr: (chunk) => process.stderr.write(chunk),
    })

    if (result.truncated) {
      process.stderr.write("\nSandbox output was truncated by Railway.\n")
    }

    if (result.timedOut) {
      process.stderr.write("\nSandbox command timed out after " + options.timeoutSec + "s.\n")
    }

    process.exitCode = result.exitCode ?? 1
  } finally {
    if (created && !options.keep) {
      await sandbox.destroy()
    }
  }
}

async function repoCheck(options) {
  requireRailwayEnvironment()
  const remoteUrl = process.env.RAILWAY_SANDBOX_REPO_URL ?? currentGitRemoteUrl()
  const repoSlug = normalizeGitHubRepoSlug(remoteUrl)
  const ref = options.ref ?? process.env.RAILWAY_SANDBOX_GIT_REF ?? currentGitRef()
  const command = resolveRepoCheckCommand(options.commandArgs)

  const sandbox = await Sandbox.create(sandboxCreateOptions(options, githubTokenEnv()))
  printSandbox(sandbox)

  try {
    const result = await sandbox.exec(buildRepoCheckCommand({ repoSlug, ref, command }), {
      timeoutSec: options.timeoutSec,
      onStdout: (chunk) => process.stdout.write(chunk),
      onStderr: (chunk) => process.stderr.write(chunk),
    })

    if (result.truncated) {
      process.stderr.write("\nSandbox output was truncated by Railway.\n")
    }

    if (result.timedOut) {
      process.stderr.write("\nSandbox repo-check timed out after " + options.timeoutSec + "s.\n")
    }

    process.exitCode = result.exitCode ?? 1
  } finally {
    if (!options.keep) {
      await sandbox.destroy()
    }
  }
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv)

  switch (options.command) {
    case "help":
      process.stdout.write(helpText)
      break
    case "list":
      await listSandboxes(options)
      break
    case "create":
      await createSandbox(options)
      break
    case "destroy":
      await destroySandbox(options)
      break
    case "exec":
      await runExec(options)
      break
    case "repo-check":
      await repoCheck(options)
      break
    default:
      throw new UsageError("Unknown command: " + options.command)
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    if (error instanceof UsageError) {
      process.stderr.write(error.message + "\n\n" + helpText)
      process.exit(2)
    }

    throw error
  })
}
