export type EdgeLogLevel = "log" | "warn" | "error"

interface EdgeLogContext {
  [key: string]: unknown
}

function serializeError(error: unknown) {
  if (error instanceof Error) {
    const details = error as Error & { code?: string; status?: number }
    return {
      message: error.message,
      name: error.name,
      code: details.code ?? null,
      status: details.status ?? null,
      stack: error.stack ?? null,
    }
  }

  return {
    message: String(error),
    name: "UnknownError",
    code: null,
    status: null,
    stack: null,
  }
}

export function toError(error: unknown): Error {
  if (error instanceof Error) {
    return error
  }

  return new Error(String(error))
}

export function logEdgeEvent(level: EdgeLogLevel, message: string, context: EdgeLogContext = {}) {
  const payload = {
    timestamp: new Date().toISOString(),
    level,
    message,
    ...context,
  }

  console[level](JSON.stringify(payload))
}

export function errorContext(error: unknown, extra: EdgeLogContext = {}) {
  return {
    ...extra,
    error: serializeError(error),
  }
}
