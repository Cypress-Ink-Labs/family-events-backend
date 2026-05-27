import { CancelledError } from "./errors"

export function createAbortController(): AbortController {
  const controller = new AbortController()
  const abort = () => controller.abort(new CancelledError())
  process.once("SIGINT", abort)
  process.once("SIGTERM", abort)
  return controller
}
