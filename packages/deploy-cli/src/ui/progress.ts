import ora, { type Ora } from "ora"

export function createSpinner(message: string | undefined, enabled: boolean): Ora | undefined {
  if (!enabled) return undefined
  if (!message) return undefined
  return ora(message).start()
}
