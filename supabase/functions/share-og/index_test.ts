import {
  extractEventIdFromRequest,
  pickOgImage,
  truncateOgDescription,
} from "./index.ts"

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

if (typeof Deno !== "undefined") {
  Deno.test("extractEventIdFromRequest resolves query parameter first", () => {
    const url = new URL("https://app.example.com/functions/v1/share-og?eventId=evt-123")
    assertEquals(extractEventIdFromRequest(url), "evt-123")
  })

  Deno.test("extractEventIdFromRequest resolves path segment fallback", () => {
    const url = new URL("https://app.example.com/functions/v1/share-og/evt-456")
    assertEquals(extractEventIdFromRequest(url), "evt-456")
  })

  Deno.test("pickOgImage returns first valid HTTPS image URL", () => {
    const image = pickOgImage(
      ["http://example.com/not-https.jpg", "https://cdn.example.com/event.webp"],
      "https://app.example.com"
    )
    assertEquals(image, "https://cdn.example.com/event.webp")
  })

  Deno.test("pickOgImage falls back when candidate list is invalid", () => {
    const image = pickOgImage(["javascript:alert(1)", "https://cdn.example.com/readme.txt"], "https://app.example.com")
    assertEquals(image, "https://app.example.com/og-fallback.png")
  })

  Deno.test("truncateOgDescription enforces max OG description length", () => {
    const longValue = "x".repeat(260)
    const truncated = truncateOgDescription(longValue)
    assertEquals(truncated.length, 200)
    assertEquals(truncated.endsWith("..."), true)
  })
}
