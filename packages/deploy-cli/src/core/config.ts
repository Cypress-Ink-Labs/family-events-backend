import { existsSync, readFileSync } from "node:fs"
import path from "node:path"
import { z } from "zod"
import { ValidationError } from "./errors"
import type { DeployConfig, EnvironmentName } from "./types"

const environmentSchema = z.object({
  supabase: z.object({
    projectRefFile: z.string().min(1),
    projectRefEnv: z.string().min(1),
  }),
})

const railwayServiceSchema = z.object({
  name: z.string().min(1),
  rootDirectory: z.string().min(1).nullable(),
  pollTimeoutSeconds: z.number().int().positive(),
  allowAutoCreate: z.boolean(),
  bootstrapFromService: z.string().min(1).optional(),
})

const deployConfigSchema = z.object({
  environments: z.object({
    production: environmentSchema,
  }),
  supabase: z.object({
    functions: z.array(z.string().min(1)).min(1),
    noVerifyJwtFunctions: z.array(z.string().min(1)),
  }),
  railway: z.object({
    allOrder: z.array(z.string().min(1)).min(1),
    services: z.array(railwayServiceSchema).min(1),
  }),
  smoke: z.object({
    functionDrift: z.boolean(),
    cronEnabledProbe: z.object({
      enabledWhenEnvPresent: z.boolean(),
      label: z.string().min(1),
    }),
  }),
})

export function repoRootFrom(startDir = process.cwd()): string {
  let dir = path.resolve(startDir)
  while (dir !== path.dirname(dir)) {
    if (
      existsSync(path.join(dir, "pnpm-workspace.yaml")) &&
      existsSync(path.join(dir, "package.json"))
    ) {
      return dir
    }
    dir = path.dirname(dir)
  }
  throw new ValidationError("Could not locate repository root")
}

export function loadConfig(rootDir: string): DeployConfig {
  const configPath = path.join(rootDir, "config", "deploy.config.json")
  if (!existsSync(configPath)) {
    throw new ValidationError(`Deploy config not found: ${configPath}`)
  }

  const raw = JSON.parse(readFileSync(configPath, "utf8")) as unknown
  const parsed = deployConfigSchema.safeParse(raw)
  if (!parsed.success) {
    throw new ValidationError(`Invalid deploy config: ${z.prettifyError(parsed.error)}`)
  }

  validateConfigConsistency(parsed.data)
  return parsed.data
}

export function resolveProjectRef(
  rootDir: string,
  config: DeployConfig,
  env: EnvironmentName
): string | undefined {
  const envConfig = config.environments[env]
  const fromEnv = process.env[envConfig.supabase.projectRefEnv]
  if (fromEnv && fromEnv.trim()) {
    return fromEnv.trim()
  }

  const refPath = path.join(rootDir, envConfig.supabase.projectRefFile)
  if (existsSync(refPath)) {
    const fromFile = readFileSync(refPath, "utf8").trim()
    return fromFile || undefined
  }

  return undefined
}

function validateConfigConsistency(config: DeployConfig): void {
  const functionNames = new Set(config.supabase.functions)
  for (const fn of config.supabase.noVerifyJwtFunctions) {
    if (!functionNames.has(fn)) {
      throw new ValidationError(`noVerifyJwtFunctions contains unknown function: ${fn}`)
    }
  }

  const services = new Set(config.railway.services.map((service) => service.name))
  for (const service of config.railway.allOrder) {
    if (!services.has(service)) {
      throw new ValidationError(`railway.allOrder contains unknown service: ${service}`)
    }
  }
}
