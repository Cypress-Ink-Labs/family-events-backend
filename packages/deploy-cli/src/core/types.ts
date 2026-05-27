export type EnvironmentName = "production"

export type TargetKind =
  | "supabase:migrations"
  | "supabase:functions:all"
  | "supabase:function"
  | "railway:all"
  | "railway:service"

export type ExitCode = 0 | 1 | 2 | 3 | 4 | 5

export interface SupabaseEnvironmentConfig {
  projectRefFile: string
  projectRefEnv: string
}

export interface DeployEnvironmentConfig {
  supabase: SupabaseEnvironmentConfig
}

export interface SupabaseConfig {
  functions: string[]
  noVerifyJwtFunctions: string[]
}

export interface RailwayServiceConfig {
  name: string
  rootDirectory: string | null
  pollTimeoutSeconds: number
  allowAutoCreate: boolean
  bootstrapFromService?: string
}

export interface RailwayConfig {
  allOrder: string[]
  services: RailwayServiceConfig[]
}

export interface SmokeConfig {
  functionDrift: boolean
  cronEnabledProbe: {
    enabledWhenEnvPresent: boolean
    label: string
  }
}

export interface DeployConfig {
  environments: Record<EnvironmentName, DeployEnvironmentConfig>
  supabase: SupabaseConfig
  railway: RailwayConfig
  smoke: SmokeConfig
}

export interface DeployTarget {
  id: string
  label: string
  kind: TargetKind
  name?: string
}

export interface DeployOptions {
  env: EnvironmentName
  all: boolean
  targets: string[]
  dryRun: boolean
  yes: boolean
  interactive: boolean
  json: boolean
  showOutput: boolean
  functionConcurrency: number
  railwayConcurrency: number
  verbose: boolean
  debug: boolean
  color: boolean
  poll: boolean
  pollTimeoutSeconds?: number
  smoke: boolean
  allowProdSmoke: boolean
}

export interface CommandRecord {
  command: string
  args: string[]
  cwd: string
  dryRun: boolean
  exitCode?: number
}

export interface TargetResult {
  targetId: string
  status: "success" | "failed" | "skipped"
  startedAt: string
  finishedAt: string
  commands: CommandRecord[]
  error?: string
  rollback?: string[]
}

export interface SmokeResult {
  name: string
  status: "success" | "failed" | "skipped"
  message: string
}

export interface DeployRunResult {
  runId: string
  env: EnvironmentName
  dryRun: boolean
  startedAt: string
  finishedAt: string
  targets: TargetResult[]
  smoke: SmokeResult[]
  artifactPath?: string
}

export interface ProcessResult {
  stdout: string
  stderr: string
  exitCode: number
}

export interface ProcessRunner {
  run(
    command: string,
    args: string[],
    options?: { cwd?: string; allowFailure?: boolean }
  ): Promise<ProcessResult>
  records: CommandRecord[]
}
