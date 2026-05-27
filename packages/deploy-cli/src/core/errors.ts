import type { ExitCode } from "./types"

export class CliError extends Error {
  readonly exitCode: ExitCode

  constructor(message: string, exitCode: ExitCode, options?: { cause?: unknown }) {
    super(message, options)
    this.name = "CliError"
    this.exitCode = exitCode
  }
}

export class ValidationError extends CliError {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, 2, options)
    this.name = "ValidationError"
  }
}

export class AuthError extends CliError {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, 4, options)
    this.name = "AuthError"
  }
}

export class CancelledError extends CliError {
  constructor(message = "Deployment cancelled") {
    super(message, 3)
    this.name = "CancelledError"
  }
}

export class SmokeError extends CliError {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, 5, options)
    this.name = "SmokeError"
  }
}

export function exitCodeFor(error: unknown): ExitCode {
  if (error instanceof CliError) {
    return error.exitCode
  }
  return 1
}

export function messageFor(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }
  return String(error)
}
