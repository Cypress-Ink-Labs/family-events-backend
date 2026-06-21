import { assertEquals } from "jsr:@std/assert"
import {
  deriveIsOutdoorFromParsedEvent,
  deriveRawImageCandidates,
  importParsedSourceEvents,
  sanitizeImagesForIngest,
} from "./process-source.ts"
import type { EventSourceRow, ParsedEvent } from "./types.ts"

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

  Deno.test("deriveRawImageCandidates keeps parser-discovered URLs and imageUrl fallback", () => {
    const parsed = buildParsedEvent({
      imageUrl: "https://cdn.example.com/hero.jpg",
      images: [
        "https://cdn.example.com/a.jpg",
        "https://cdn.example.com/a.jpg",
        "javascript:alert(1)",
      ],
    })

    assertEquals(deriveRawImageCandidates(parsed), [
      "https://cdn.example.com/a.jpg",
      "https://cdn.example.com/hero.jpg",
    ])
  })

  Deno.test("deriveRawImageCandidates caps candidates at 20", () => {
    const parsed = buildParsedEvent({
      images: Array.from({ length: 25 }, (_, i) => `https://cdn.example.com/${i}.jpg`),
    })

    assertEquals(deriveRawImageCandidates(parsed).length, 20)
  })

  Deno.test("sanitizeImagesForIngest enforces 2MB size cap and image content-type", async () => {
    const originalFetch = globalThis.fetch
    try {
      globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
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
        if (url.pathname === "/ok-no-length.jpg") {
          if (init?.method === "HEAD") {
            return Promise.resolve(
              new Response(null, {
                status: 200,
                headers: { "content-type": "image/jpeg" },
              })
            )
          }
          return Promise.resolve(
            new Response(new Uint8Array(1024), {
              status: 200,
              headers: { "content-type": "image/jpeg" },
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
          "https://events.example.com/ok-no-length.jpg",
        ],
      })

      const images = await sanitizeImagesForIngest(parsed, "https://events.example.com/feed", {
        // Inject a no-op SSRF resolver so the test exercises the fetch/validation
        // logic without real DNS (which would need --allow-net and a resolvable host).
        resolve: () => Promise.resolve({ ok: true }),
      })
      assertEquals(images, [
        "https://events.example.com/ok.jpg",
        "https://events.example.com/ok-no-length.jpg",
      ])
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

      const images = await sanitizeImagesForIngest(parsed, "https://events.example.com/feed", {
        // Inject a no-op SSRF resolver so the test exercises the fetch/validation
        // logic without real DNS (which would need --allow-net and a resolvable host).
        resolve: () => Promise.resolve({ ok: true }),
      })
      assertEquals(images, [])
      assertEquals(fetchCalls, 0)
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  // ── importParsedSourceEvents: cross-source dedup pre-pass ─────────────────

  /**
   * Minimal fake SupabaseClient that handles all DB calls made by
   * importParsedSourceEvents:
   *   - .from("cities").select().eq().maybeSingle()  → centroid
   *   - .from("source_runs").update().eq()           → progress flushes
   *   - .from("event_sources").update().eq()         → finalize
   *   - .rpc("find_cross_source_event_candidates")   → controlled by caller
   *   - .rpc("bulk_import_scrape_events")            → returns fixed counts
   *   - .rpc("invoke_process_tag_queue")             → no-op
   */
  class FakeSupabase {
    // Caller sets these to control which RPC responses are returned.
    crossSourceCandidates: Array<{
      id: string
      title: string
      source_id: string
      start_datetime: string
    }> = []
    crossSourceCandidateError: { code?: string; message?: string } | null = null

    // Track what was passed to the bulk RPC.
    bulkRpcCalls: Array<Record<string, unknown>[]> = []

    rpc(name: string, args?: Record<string, unknown>) {
      if (name === "find_cross_source_event_candidates") {
        if (this.crossSourceCandidateError) {
          return Promise.resolve({ data: null, error: this.crossSourceCandidateError })
        }
        return Promise.resolve({ data: this.crossSourceCandidates, error: null })
      }

      if (name === "bulk_import_scrape_events") {
        const events = (args?.p_events ?? []) as Record<string, unknown>[]
        this.bulkRpcCalls.push(events)
        return Promise.resolve({
          data: { imported: events.length, updated: 0, skipped: 0, enqueued: events.length },
          error: null,
        })
      }

      if (name === "invoke_process_tag_queue") {
        return Promise.resolve({ data: null, error: null })
      }

      throw new Error(`Unhandled rpc: ${name}`)
    }

    from(table: string) {
      return new FakeQuery(table)
    }
  }

  class FakeQuery {
    constructor(private readonly table: string) {}

    select(_cols?: string) {
      return this
    }
    update(_payload?: Record<string, unknown>) {
      return this
    }
    eq(_col?: string, _val?: unknown) {
      return this
    }
    maybeSingle() {
      if (this.table === "cities") {
        return Promise.resolve({ data: { latitude: 30.45, longitude: -91.19 }, error: null })
      }
      return Promise.resolve({ data: null, error: null })
    }
    // Allow `.update().eq()` to resolve via then-able (no-op)
    then<T>(
      onfulfilled?: ((value: { data: null; error: null }) => T | PromiseLike<T>) | null
    ): Promise<T> {
      return Promise.resolve({ data: null, error: null }).then(onfulfilled)
    }
  }

  function buildSource(overrides: Partial<EventSourceRow> = {}): EventSourceRow {
    return {
      id: "source-a",
      name: "Test Source A",
      url: "https://example.com/feed",
      source_type: "rss",
      extraction_mode: "deterministic",
      city_id: "city-1",
      is_active: true,
      auto_approve: false,
      scrape_interval_hours: 24,
      last_scraped_at: null,
      last_status: null,
      error_count: 0,
      date_window_days: null,
      ...overrides,
    }
  }

  function buildParsedEventForDedup(overrides: Partial<ParsedEvent> = {}): ParsedEvent {
    return {
      title: "Family Story Time",
      description: "A fun event for kids",
      startDatetime: "2026-06-20T14:00:00.000Z",
      endDatetime: null,
      venueName: "City Library",
      address: "100 Main St",
      sourceUrl: "https://example.com/event/1",
      imageUrl: null,
      images: [],
      price: null,
      isFree: true,
      ...overrides,
    }
  }

  Deno.test("importParsedSourceEvents: cross-source duplicate is skipped (not sent to bulk_import)", async () => {
    const db = new FakeSupabase()
    // Existing event from a DIFFERENT source with same title + time
    db.crossSourceCandidates = [
      {
        id: "event-existing-1",
        title: "Family Story Time",
        source_id: "source-b", // different source
        start_datetime: "2026-06-20T14:00:00.000Z",
      },
    ]

    const source = buildSource({ id: "source-a", city_id: "city-1" })
    const parsedEvents = [buildParsedEventForDedup()]

    const result = await importParsedSourceEvents(db as never, source, "run-1", parsedEvents)

    // The event must have been skipped — bulk_import called with empty array
    assertEquals(db.bulkRpcCalls.length, 1)
    assertEquals(db.bulkRpcCalls[0].length, 0)
    // eventsSkipped should reflect the cross-source skip
    assertEquals(result.eventsSkipped, 1)
  })

  Deno.test("importParsedSourceEvents: same-source candidate is NOT skipped", async () => {
    const db = new FakeSupabase()
    // Candidate from the SAME source — should not be filtered by dedup
    db.crossSourceCandidates = [
      {
        id: "event-existing-2",
        title: "Family Story Time",
        source_id: "source-a", // same source
        start_datetime: "2026-06-20T14:00:00.000Z",
      },
    ]

    const source = buildSource({ id: "source-a", city_id: "city-1" })
    const parsedEvents = [buildParsedEventForDedup()]

    await importParsedSourceEvents(db as never, source, "run-2", parsedEvents)

    // Not filtered by dedup — must be passed to bulk_import
    assertEquals(db.bulkRpcCalls.length, 1)
    assertEquals(db.bulkRpcCalls[0].length, 1)
  })

  Deno.test("importParsedSourceEvents: city_id null bypasses dedup entirely", async () => {
    const db = new FakeSupabase()
    // Even with cross-source candidates configured, dedup should not run
    db.crossSourceCandidates = [
      {
        id: "event-existing-3",
        title: "Family Story Time",
        source_id: "source-b",
        start_datetime: "2026-06-20T14:00:00.000Z",
      },
    ]

    const source = buildSource({ id: "source-a", city_id: null })
    const parsedEvents = [buildParsedEventForDedup()]

    await importParsedSourceEvents(db as never, source, "run-3", parsedEvents)

    // All events passed through — dedup skipped when city_id is null
    assertEquals(db.bulkRpcCalls.length, 1)
    assertEquals(db.bulkRpcCalls[0].length, 1)
  })

  Deno.test("importParsedSourceEvents: dedup RPC missing (42883) does not break ingestion", async () => {
    const db = new FakeSupabase()
    db.crossSourceCandidateError = { code: "42883", message: "function not found" }

    const source = buildSource({ id: "source-a", city_id: "city-1" })
    const parsedEvents = [buildParsedEventForDedup()]

    const result = await importParsedSourceEvents(db as never, source, "run-4", parsedEvents)

    // Ingestion must still succeed (status = success, event imported)
    assertEquals(result.status, "success")
    assertEquals(db.bulkRpcCalls.length, 1)
    assertEquals(db.bulkRpcCalls[0].length, 1)
  })

  Deno.test("sanitizeImagesForIngest validates image candidates with bounded concurrency", async () => {
    const originalFetch = globalThis.fetch
    let active = 0
    let maxActive = 0
    try {
      globalThis.fetch = (async (input: string | URL | Request) => {
        const url = new URL(
          typeof input === "string" ? input : input instanceof URL ? input : input.url
        )
        active += 1
        maxActive = Math.max(maxActive, active)
        await new Promise((resolve) => setTimeout(resolve, 20))
        active -= 1
        return new Response(null, {
          status: 200,
          headers: { "content-type": "image/jpeg", "content-length": "1024" },
        })
      }) as typeof fetch

      const parsed = buildParsedEvent({
        images: [
          "https://events.example.com/1.jpg",
          "https://events.example.com/2.jpg",
          "https://events.example.com/3.jpg",
          "https://events.example.com/4.jpg",
        ],
      })

      const images = await sanitizeImagesForIngest(parsed, "https://events.example.com/feed", {
        // Inject a no-op SSRF resolver so the test exercises the fetch/validation
        // logic without real DNS (which would need --allow-net and a resolvable host).
        resolve: () => Promise.resolve({ ok: true }),
      })
      assertEquals(images.length, 4)
      assertEquals(maxActive, 2)
    } finally {
      globalThis.fetch = originalFetch
    }
  })
}
