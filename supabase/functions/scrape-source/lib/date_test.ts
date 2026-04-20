import { parseDateFromText } from "./date.ts"

function assert(condition: boolean, message = "Assertion failed"): void {
  if (!condition) {
    throw new Error(message)
  }
}

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

if (typeof Deno !== "undefined") {
  Deno.test("parseDateFromText returns null when no date is present", () => {
    assertEquals(parseDateFromText("no date here"), null)
  })

  Deno.test("parseDateFromText parses month-name date strings", () => {
    const parsed = parseDateFromText("Event starts Apr 15, 2026 at 7pm")
    if (parsed === null) {
      throw new Error("Expected a parsed date value")
    }
    assert(parsed.startsWith("2026-04-15T"))
  })
}
