import { Chalk } from "chalk"
import pino from "pino"
import { redact } from "./redaction"

export interface Logger {
  info(message: string): void
  warn(message: string): void
  error(message: string): void
  debug(message: string): void
  success(message: string): void
}

export function createLogger(options: {
  json: boolean
  verbose: boolean
  debug: boolean
  color: boolean
}): Logger {
  if (options.json) {
    const logger = pino({ level: options.debug ? "debug" : options.verbose ? "info" : "warn" })
    return {
      info: (message) => logger.info(redact(message)),
      warn: (message) => logger.warn(redact(message)),
      error: (message) => logger.error(redact(message)),
      debug: (message) => logger.debug(redact(message)),
      success: (message) => logger.info(redact(message)),
    }
  }

  const colorize = new Chalk({ level: options.color ? 1 : 0 })
  return {
    info: (message) => console.log(`${colorize.cyan("->")} ${redact(message)}`),
    warn: (message) => console.warn(`${colorize.yellow("!")} ${redact(message)}`),
    error: (message) => console.error(`${colorize.red("x")} ${redact(message)}`),
    debug: (message) => {
      if (options.debug) console.log(`${colorize.gray("debug")} ${redact(message)}`)
    },
    success: (message) => console.log(`${colorize.green("✓")} ${redact(message)}`),
  }
}
