import * as Sentry from "https://deno.land/x/sentry@8.55.0/index.mjs"
import { toError } from "./logger.ts"

let initialized = false

function initSentry() {
  if (initialized) {
    return
  }

  const dsn = Deno.env.get("SENTRY_DSN")
  if (!dsn) {
    initialized = true
    return
  }

  const rate = Number(Deno.env.get("SENTRY_TRACES_SAMPLE_RATE") ?? "0.1")
  Sentry.init({
    dsn,
    defaultIntegrations: false,
    tracesSampleRate: Number.isFinite(rate) ? rate : 0.1,
  })

  initialized = true
}

export async function captureEdgeException(
  error: unknown,
  context: Record<string, unknown> = {}
) {
  initSentry()
  if (!Deno.env.get("SENTRY_DSN")) {
    return
  }

  Sentry.withScope((scope) => {
    const region = Deno.env.get("SB_REGION")
    const executionId = Deno.env.get("SB_EXECUTION_ID")

    if (region) {
      scope.setTag("region", region)
    }
    if (executionId) {
      scope.setTag("execution_id", executionId)
    }

    for (const [key, value] of Object.entries(context)) {
      if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
        scope.setTag(key, String(value))
      }
    }

    scope.setContext("edge_function", context)
    Sentry.captureException(toError(error))
  })

  await Sentry.flush(2000)
}
