import { ValidationError } from "./errors"
import type { DeployConfig, DeployTarget } from "./types"

export function allTargets(config: DeployConfig): DeployTarget[] {
  return [
    { id: "supabase:migrations", label: "Supabase DB migrations", kind: "supabase:migrations" },
    {
      id: "supabase:functions:all",
      label: "Supabase all functions",
      kind: "supabase:functions:all",
    },
    ...config.supabase.functions.map((name) => ({
      id: `supabase:function:${name}`,
      label: `Supabase function: ${name}`,
      kind: "supabase:function" as const,
      name,
    })),
    { id: "railway:all", label: "Railway all services", kind: "railway:all" },
    ...config.railway.services.map((service) => ({
      id: `railway:${service.name}`,
      label: `Railway service: ${service.name}`,
      kind: "railway:service" as const,
      name: service.name,
    })),
  ]
}

export function resolveTargets(
  config: DeployConfig,
  requested: string[],
  all: boolean
): DeployTarget[] {
  const byId = new Map(allTargets(config).map((target) => [target.id, target]))
  const selected = all
    ? [byId.get("supabase:migrations"), byId.get("supabase:functions:all"), byId.get("railway:all")]
    : requested.map((id) => byId.get(normalizeTargetId(id)))

  const missing = requested.map(normalizeTargetId).filter((id) => !byId.has(id))
  if (missing.length > 0) {
    throw new ValidationError(`Unknown deploy target(s): ${missing.join(", ")}`)
  }

  const deduped = dedupeTargets(
    selected.filter((target): target is DeployTarget => Boolean(target))
  )
  if (deduped.length === 0) {
    throw new ValidationError("No deployment targets selected")
  }
  return deduped
}

export function expandTarget(config: DeployConfig, target: DeployTarget): DeployTarget[] {
  if (target.kind === "supabase:functions:all") {
    return config.supabase.functions.map((name) => ({
      id: `supabase:function:${name}`,
      label: `Supabase function: ${name}`,
      kind: "supabase:function",
      name,
    }))
  }
  if (target.kind === "railway:all") {
    return config.railway.allOrder.map((name) => ({
      id: `railway:${name}`,
      label: `Railway service: ${name}`,
      kind: "railway:service",
      name,
    }))
  }
  return [target]
}

export function normalizeTargetId(input: string): string {
  const value = input.trim()
  if (value.startsWith("supabase:") || value.startsWith("railway:")) {
    return value
  }
  return `railway:${value}`
}

function dedupeTargets(targets: DeployTarget[]): DeployTarget[] {
  const hasSupabaseAll = targets.some((target) => target.kind === "supabase:functions:all")
  const hasRailwayAll = targets.some((target) => target.kind === "railway:all")
  const seen = new Set<string>()
  const output: DeployTarget[] = []

  for (const target of targets) {
    if (hasSupabaseAll && target.kind === "supabase:function") continue
    if (hasRailwayAll && target.kind === "railway:service") continue
    if (seen.has(target.id)) continue
    seen.add(target.id)
    output.push(target)
  }

  return output
}
