import { assertEquals, assertExists } from "jsr:@std/assert"
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

  // ---------------------------------------------------------------------------
  // Stale-escalation tests
  // ---------------------------------------------------------------------------

  /**
   * Builds a minimal EventSourceRow for stale-escalation tests.
   * consecutive_zero_result_scrapes defaults to 0, stale_escalated_at to null.
   */
  function buildSource(overrides: Partial<EventSourceRow> = {}): EventSourceRow {
    return {
      id: "src-1",
      name: "Test Source",
      url: "https://events.example.com/feed",
      source_type: "rss",
      extraction_mode: "deterministic",
      processing_mode: null,
      city_id: null,
      is_active: true,
      auto_approve: false,
      scrape_interval_hours: 24,
      last_scraped_at: null,
      last_status: "success",
      error_count: 0,
      date_window_days: null,
      consecutive_zero_result_scrapes: 0,
      stale_escalated_at: null,
      ...overrides,
    }
  }

  /**
   * Builds a minimal supabase client mock that:
   * - Returns empty data for city lookups (city_id is null, so never called).
   * - Returns the given bulkResult for bulk_import_scrape_events RPC calls.
   * - Captures the last update() payload for each table.
   * - Captures all insert() payloads for admin_audit_log.
   */
  function buildSupabaseMock(opts: {
    bulkResult?: { imported: number; updated: number; skipped: number; enqueued: number }
    // When set, admin_audit_log.insert() resolves with this error (the supabase
    // client surfaces DB errors in the response object, not via throw).
    auditInsertError?: { message: string }
  } = {}) {
    const captured: {
      eventSourceUpdate: Record<string, unknown> | null
      auditLogInserts: unknown[]
    } = {
      eventSourceUpdate: null,
      auditLogInserts: [],
    }

    const bulkResult = opts.bulkResult ?? { imported: 0, updated: 0, skipped: 0, enqueued: 0 }

    // Each .from(table) returns a builder whose methods return themselves or
    // terminal promises. We only model the chains that process-source.ts uses.
    function makeBuilder(table: string): Record<string, unknown> {
      const builder: Record<string, (...args: unknown[]) => unknown> = {}

      // .select() → builder (for cities maybeSingle path)
      builder.select = () => makeBuilder(table)

      // .eq() → builder
      builder.eq = () => makeBuilder(table)

      // .maybeSingle() → terminal (for cities lookup)
      builder.maybeSingle = () => Promise.resolve({ data: null, error: null })

      // .update(payload) → builder that remembers the payload
      builder.update = (payload: unknown) => {
        if (table === "event_sources") {
          captured.eventSourceUpdate = payload as Record<string, unknown>
        }
        return makeBuilder(table)
      }

      // .insert(payload) → terminal (for admin_audit_log)
      builder.insert = (payload: unknown) => {
        if (table === "admin_audit_log") {
          captured.auditLogInserts.push(payload)
          if (opts.auditInsertError) {
            return Promise.resolve({ data: null, error: opts.auditInsertError })
          }
        }
        return Promise.resolve({ data: null, error: null })
      }

      return builder
    }

    const client = {
      from: (table: string) => makeBuilder(table),
      rpc: (name: string, _args?: unknown) => {
        if (name === "bulk_import_scrape_events") {
          return Promise.resolve({ data: bulkResult, error: null })
        }
        if (name === "invoke_process_tag_queue") {
          return Promise.resolve({ data: null, error: null })
        }
        return Promise.resolve({ data: null, error: null })
      },
    }

    return { client, captured }
  }

  Deno.test(
    "stale escalation: 3 consecutive zero-result scrapes triggers stale status and audit log",
    async () => {
      // Source has already seen 2 consecutive zero-result scrapes.
      const source = buildSource({ consecutive_zero_result_scrapes: 2, stale_escalated_at: null })
      const { client, captured } = buildSupabaseMock({
        bulkResult: { imported: 0, updated: 0, skipped: 0, enqueued: 0 },
      })

      // Pass 0 parsedEvents → eventsFound=0 → zero-result success path.
      await importParsedSourceEvents(
        client as unknown as Parameters<typeof importParsedSourceEvents>[0],
        source,
        "run-1",
        []
      )

      // event_sources update should set last_status='stale', consecutive=3, stale_escalated_at set.
      assertExists(captured.eventSourceUpdate, "event_sources update was not called")
      assertEquals(captured.eventSourceUpdate!.last_status, "stale")
      assertEquals(captured.eventSourceUpdate!.consecutive_zero_result_scrapes, 3)
      assertExists(
        captured.eventSourceUpdate!.stale_escalated_at,
        "stale_escalated_at should be set"
      )

      // admin_audit_log insert should have been fired once.
      assertEquals(captured.auditLogInserts.length, 1)
      const auditRow = captured.auditLogInserts[0] as Record<string, unknown>
      assertEquals(auditRow.action, "source.stale_escalated")
      assertEquals(auditRow.target_type, "event_source")
      assertEquals(auditRow.target_id, "src-1")
      assertEquals(auditRow.admin_user_id, null)
    }
  )

  Deno.test(
    "stale escalation: non-zero import resets consecutive_zero_result_scrapes to 0",
    async () => {
      const source = buildSource({ consecutive_zero_result_scrapes: 2, stale_escalated_at: null })
      const { client, captured } = buildSupabaseMock({
        // 1 event imported → eventsImported > 0 → not a zero-result run.
        bulkResult: { imported: 1, updated: 0, skipped: 0, enqueued: 1 },
      })

      const parsedEvent = buildParsedEvent()
      await importParsedSourceEvents(
        client as unknown as Parameters<typeof importParsedSourceEvents>[0],
        source,
        "run-2",
        [parsedEvent]
      )

      assertExists(captured.eventSourceUpdate, "event_sources update was not called")
      assertEquals(captured.eventSourceUpdate!.consecutive_zero_result_scrapes, 0)
      assertEquals(captured.eventSourceUpdate!.last_status, "success")
      // stale_escalated_at should NOT be set (no escalation).
      assertEquals(
        captured.eventSourceUpdate!.stale_escalated_at,
        undefined,
        "stale_escalated_at should not be set when events are imported"
      )
      // No audit log entry.
      assertEquals(captured.auditLogInserts.length, 0)
    }
  )

  Deno.test(
    "stale escalation: already-escalated source does not re-alert or overwrite timestamp",
    async () => {
      const existingTimestamp = "2026-06-19T00:00:00.000Z"
      const source = buildSource({
        consecutive_zero_result_scrapes: 5,
        stale_escalated_at: existingTimestamp,
      })
      const { client, captured } = buildSupabaseMock({
        bulkResult: { imported: 0, updated: 0, skipped: 0, enqueued: 0 },
      })

      await importParsedSourceEvents(
        client as unknown as Parameters<typeof importParsedSourceEvents>[0],
        source,
        "run-3",
        []
      )

      assertExists(captured.eventSourceUpdate, "event_sources update was not called")
      // consecutive counter still increments (tracking), but no re-escalation.
      assertEquals(captured.eventSourceUpdate!.consecutive_zero_result_scrapes, 6)
      // last_status stays "success" (zero-result, no events found — not re-escalated).
      assertEquals(captured.eventSourceUpdate!.last_status, "success")
      // stale_escalated_at NOT in the update payload (idempotent).
      assertEquals(
        captured.eventSourceUpdate!.stale_escalated_at,
        undefined,
        "stale_escalated_at should not be overwritten on already-escalated source"
      )
      // No second audit log entry.
      assertEquals(captured.auditLogInserts.length, 0)
    }
  )

  Deno.test(
    "stale escalation: audit-log insert error stays non-fatal and still escalates",
    async () => {
      const source = buildSource({ consecutive_zero_result_scrapes: 2, stale_escalated_at: null })
      const { client, captured } = buildSupabaseMock({
        bulkResult: { imported: 0, updated: 0, skipped: 0, enqueued: 0 },
        // admin_audit_log.insert resolves with an error (RLS/constraint) — not a throw.
        auditInsertError: { message: "permission denied for table admin_audit_log" },
      })

      // Must not throw even though the audit write fails.
      await importParsedSourceEvents(
        client as unknown as Parameters<typeof importParsedSourceEvents>[0],
        source,
        "run-4",
        []
      )

      // Escalation still happened on event_sources despite the audit failure.
      assertExists(captured.eventSourceUpdate, "event_sources update was not called")
      assertEquals(captured.eventSourceUpdate!.last_status, "stale")
      assertEquals(captured.eventSourceUpdate!.consecutive_zero_result_scrapes, 3)
      // Insert was attempted exactly once.
      assertEquals(captured.auditLogInserts.length, 1)
    }
  )

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
