import { SmokeError } from "../core/errors"
import type { DeployConfig, SmokeResult } from "../core/types"
import { SupabaseProvider } from "../providers/supabase"

export async function runSmokeChecks(
  config: DeployConfig,
  supabase: SupabaseProvider
): Promise<SmokeResult[]> {
  const results: SmokeResult[] = []

  if (config.smoke.functionDrift) {
    try {
      const filesystem = supabase.discoverFunctions()
      const remote = await supabase.listRemoteFunctions()
      if (remote.length > 0 && filesystem.join("\n") !== remote.join("\n")) {
        results.push({
          name: "supabase:function-drift",
          status: "failed",
          message: `Filesystem functions differ from deployed functions. filesystem=${filesystem.join(",")} remote=${remote.join(",")}`,
        })
      } else {
        results.push({
          name: "supabase:function-drift",
          status: "success",
          message: "Function list matches or remote list unavailable",
        })
      }
    } catch (error) {
      results.push({
        name: "supabase:function-drift",
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      })
    }
  }

  const supabaseUrl = process.env.SUPABASE_URL
  const serviceKey = process.env.SUPABASE_SERVICE_KEY
  if (config.smoke.cronEnabledProbe.enabledWhenEnvPresent && supabaseUrl && serviceKey) {
    try {
      const response = await fetch(`${supabaseUrl}/rest/v1/rpc/is_cron_enabled`, {
        method: "POST",
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_label: config.smoke.cronEnabledProbe.label }),
      })
      if (!response.ok) {
        results.push({
          name: "supabase:is-cron-enabled",
          status: "failed",
          message: `HTTP ${response.status}`,
        })
      } else {
        results.push({
          name: "supabase:is-cron-enabled",
          status: "success",
          message: `${config.smoke.cronEnabledProbe.label}=${await response.text()}`,
        })
      }
    } catch (error) {
      results.push({
        name: "supabase:is-cron-enabled",
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      })
    }
  } else {
    results.push({
      name: "supabase:is-cron-enabled",
      status: "skipped",
      message: "SUPABASE_URL or SUPABASE_SERVICE_KEY not set",
    })
  }

  if (results.some((result) => result.status === "failed")) {
    throw new SmokeError("One or more smoke checks failed")
  }

  return results
}
