import ora, { type Ora } from "ora"

export function createSpinner(message: string, enabled: boolean): Ora | undefined {
  if (!enabled) return undefined
  return ora(message).start()
}
