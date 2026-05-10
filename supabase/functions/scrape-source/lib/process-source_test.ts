import { deriveIsOutdoorFromParsedEvent, sanitizeImagesForIngest } from "./process-source.ts"
import type { ParsedEvent } from "./types.ts"

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

function assertDeepEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

function buildParsedEvent(overrides: Partial<ParsedEvent> = {}): ParsedEvent {
  return {
    title: "Family Story Time",
    description: "Join us at the city library this Saturday.",
    startDatetime: "2026-05-10T14:00:00.000Z",
    endDatetime: null,
    venueName: "Main Library",
    address: "10 Main St",
    sourceUrl: "https://events.example.com/event/story-time",
    imageUrl: null,
    images: [],
    price: null,
    isFree: false,
    ...overrides,
  }
}

if (typeof Deno !== "undefined") {
  Deno.test("deriveIsOutdoorFromParsedEvent returns true for outdoor keyword signals", () => {
    const parsed = buildParsedEvent({
      description: "Outdoor meetup in the neighborhood park with a short hike.",
      venueName: "River Walk",
    })
    assertEquals(deriveIsOutdoorFromParsedEvent(parsed), true)
  })

  Deno.test("deriveIsOutdoorFromParsedEvent returns false for indoor keyword signals", () => {
    const parsed = buildParsedEvent({
      description: "Hands-on museum program inside the library annex.",
    })
    assertEquals(deriveIsOutdoorFromParsedEvent(parsed), false)
  })

  Deno.test("deriveIsOutdoorFromParsedEvent returns null for conflicting signals", () => {
    const parsed = buildParsedEvent({
      description: "Start at the museum, then head outside to the park playground.",
    })
    assertEquals(deriveIsOutdoorFromParsedEvent(parsed), null)
  })

  Deno.test("sanitizeImagesForIngest enforces 2MB size cap and image content-type", async () => {
    const originalFetch = globalThis.fetch
    try {
      globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
        if (init?.method !== "HEAD") {
          throw new Error("Expected HEAD request")
        }

        const url = new URL(
          typeof input === "string" ? input : input instanceof URL ? input : input.url
        )
        if (url.pathname === "/too-big.jpg") {
          return Promise.resolve(
            new Response(null, {
              status: 200,
              headers: {
                "content-type": "image/jpeg",
                "content-length": String(2 * 1024 * 1024 + 1),
              },
            })
          )
        }
        if (url.pathname === "/wrong-type.jpg") {
          return Promise.resolve(
            new Response(null, {
              status: 200,
              headers: { "content-type": "text/html", "content-length": "1024" },
            })
          )
        }
        if (url.pathname === "/ok.jpg") {
          return Promise.resolve(
            new Response(null, {
              status: 200,
              headers: { "content-type": "image/jpeg", "content-length": "1024" },
            })
          )
        }
        return Promise.resolve(new Response(null, { status: 404 }))
      }) as typeof fetch

      const parsed = buildParsedEvent({
        images: [
          "https://events.example.com/too-big.jpg",
          "https://events.example.com/wrong-type.jpg",
          "https://events.example.com/ok.jpg",
        ],
      })

      const images = await sanitizeImagesForIngest(parsed, "https://events.example.com/feed")
      assertDeepEquals(images, ["https://events.example.com/ok.jpg"])
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  Deno.test("sanitizeImagesForIngest rejects hosts outside source/config allowlist", async () => {
    const originalFetch = globalThis.fetch
    let fetchCalls = 0
    try {
      globalThis.fetch = (() => {
        fetchCalls += 1
        return Promise.resolve(
          new Response(null, {
            status: 200,
            headers: { "content-type": "image/jpeg", "content-length": "1024" },
          })
        )
      }) as typeof fetch

      const parsed = buildParsedEvent({
        images: ["https://evil.example.net/bad.jpg"],
      })

      const images = await sanitizeImagesForIngest(parsed, "https://events.example.com/feed")
      assertDeepEquals(images, [])
      assertEquals(fetchCalls, 0)
    } finally {
      globalThis.fetch = originalFetch
    }
  })
}
