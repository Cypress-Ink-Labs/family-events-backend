import { describe, expect, it } from "vitest"
import {
  AuthError,
  CancelledError,
  DeployFailureError,
  exitCodeFor,
  SmokeError,
  ValidationError,
} from "../src/core/errors"

describe("deploy CLI errors", () => {
  it("maps typed errors to documented exit codes", () => {
    expect(exitCodeFor(new DeployFailureError("deploy failed"))).toBe(1)
    expect(exitCodeFor(new ValidationError("invalid config"))).toBe(2)
    expect(exitCodeFor(new CancelledError())).toBe(3)
    expect(exitCodeFor(new AuthError("auth failed"))).toBe(4)
    expect(exitCodeFor(new SmokeError("smoke failed"))).toBe(5)
  })
})
