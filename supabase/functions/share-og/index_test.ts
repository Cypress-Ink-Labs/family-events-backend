import { assertEquals } from "jsr:@std/assert"
import {
  extractEventIdFromRequest,
  pickOgImage,
  truncateOgDescription,
} from "./index.ts"

const VALID_UUID_A = "11111111-2222-4333-8444-555555555555"
const VALID_UUID_B = "aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee"

if (typeof Deno !== "undefined") {
  Deno.test("extractEventIdFromRequest resolves query parameter first", () => {
    const url = new URL(`https://app.example.com/functions/v1/share-og?eventId=${VALID_UUID_A}`)
    assertEquals(extractEventIdFromRequest(url), VALID_UUID_A)
  })

  Deno.test("extractEventIdFromRequest resolves path segment fallback", () => {
    const url = new URL(`https://app.example.com/functions/v1/share-og/${VALID_UUID_B}`)
    assertEquals(extractEventIdFromRequest(url), VALID_UUID_B)
  })

  Deno.test("extractEventIdFromRequest rejects non-UUID input", () => {
    const url = new URL("https://app.example.com/functions/v1/share-og?eventId=evt-not-a-uuid")
    assertEquals(extractEventIdFromRequest(url), null)
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
