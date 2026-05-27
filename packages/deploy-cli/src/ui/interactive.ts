import { checkbox } from "@inquirer/prompts"
import type { DeployConfig } from "../core/types"
import { allTargets } from "../core/target-graph"

export async function pickTargets(config: DeployConfig): Promise<string[]> {
  const targets = allTargets(config).filter((target) =>
    ["supabase:migrations", "supabase:functions:all", "railway:all", "railway:service"].includes(
      target.kind
    )
  )
  return checkbox({
    message: "Select targets to deploy",
    choices: targets.map((target) => ({
      name: target.label,
      value: target.id,
    })),
    required: true,
  })
}
