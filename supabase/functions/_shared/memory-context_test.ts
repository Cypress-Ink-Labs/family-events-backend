import { assertEquals } from "jsr:@std/assert"
import type { SupabaseClient } from "@supabase/supabase-js"
import {
  fetchSimilarEventTagContext,
  fetchSimilarReviewContext,
  formatTagMemoryPrompt,
  formatReviewMemoryPrompt,
  type SimilarEventTagContext,
  type SimilarEventReviewContext,
} from "./memory-context.ts"

// ── formatTagMemoryPrompt tests ──────────────────────────────────────────────

Deno.test("formatTagMemoryPrompt - returns empty string for no contexts", () => {
  assertEquals(formatTagMemoryPrompt([]), "")
})

Deno.test("formatTagMemoryPrompt - formats single event with AI tags", () => {
  const contexts: SimilarEventTagContext[] = [
    {
      eventId: "evt-1",
      title: "Kids Music Class",
      cosineDistance: 0.12,
      tags: [
        { slug: "music", name: "Music", source: "ai", confidence: 0.9 },
        { slug: "indoor", name: "Indoor", source: "ai", confidence: 0.7 },
      ],
      adminCorrected: false,
      adminReason: null,
    },
  ]

  const result = formatTagMemoryPrompt(contexts)
  assertEquals(result.includes("MEMORY CONTEXT"), true)
  assertEquals(result.includes("Kids Music Class"), true)
  assertEquals(result.includes("music"), true)
  assertEquals(result.includes("indoor"), true)
  assertEquals(result.includes("admin-corrected"), false)
})

Deno.test("formatTagMemoryPrompt - highlights admin corrections", () => {
  const contexts: SimilarEventTagContext[] = [
    {
      eventId: "evt-2",
      title: "Art Workshop for Families",
      cosineDistance: 0.15,
      tags: [
        { slug: "art", name: "Art", source: "admin", confidence: 1.0 },
        { slug: "outdoor", name: "Outdoor", source: "ai", confidence: 0.8 },
      ],
      adminCorrected: true,
      adminReason: "Added art tag, this is primarily an art event",
    },
  ]

  const result = formatTagMemoryPrompt(contexts)
  assertEquals(result.includes("admin-corrected"), true)
  assertEquals(result.includes("[ADMIN CORRECTED]"), true)
  assertEquals(result.includes("Admin reason:"), true)
  assertEquals(result.includes("primarily an art event"), true)
})

Deno.test("formatTagMemoryPrompt - includes reference instruction", () => {
  const contexts: SimilarEventTagContext[] = [
    {
      eventId: "evt-1",
      title: "Test",
      cosineDistance: 0.1,
      tags: [{ slug: "music", name: "Music", source: "ai", confidence: 0.9 }],
      adminCorrected: false,
      adminReason: null,
    },
  ]

  const result = formatTagMemoryPrompt(contexts)
  assertEquals(result.includes("Admin-corrected tags are higher-quality signals"), true)
})

// ── formatReviewMemoryPrompt tests ───────────────────────────────────────────

Deno.test("formatReviewMemoryPrompt - returns empty string for no contexts", () => {
  assertEquals(formatReviewMemoryPrompt([]), "")
})

Deno.test("formatReviewMemoryPrompt - formats approved and rejected events", () => {
  const contexts: SimilarEventReviewContext[] = [
    {
      eventId: "evt-1",
      title: "Kids Yoga",
      cosineDistance: 0.1,
      status: "published",
      llmReviewDecision: "approve",
      adminOverridden: false,
      adminDecision: null,
      adminReason: null,
    },
    {
      eventId: "evt-2",
      title: "Adult Only Event",
      cosineDistance: 0.2,
      status: "rejected",
      llmReviewDecision: "reject",
      adminOverridden: false,
      adminDecision: null,
      adminReason: null,
    },
  ]

  const result = formatReviewMemoryPrompt(contexts)
  assertEquals(result.includes("MEMORY CONTEXT"), true)
  assertEquals(result.includes("Kids Yoga"), true)
  assertEquals(result.includes("published"), true)
  assertEquals(result.includes("Adult Only Event"), true)
  assertEquals(result.includes("rejected"), true)
})

Deno.test("formatReviewMemoryPrompt - highlights admin overrides", () => {
  const contexts: SimilarEventReviewContext[] = [
    {
      eventId: "evt-1",
      title: "Community Garden Day",
      cosineDistance: 0.1,
      status: "published",
      llmReviewDecision: "needs_admin_review",
      adminOverridden: true,
      adminDecision: "published",
      adminReason: "This is a family-friendly community event",
    },
  ]

  const result = formatReviewMemoryPrompt(contexts)
  assertEquals(result.includes("admin-overridden"), true)
  assertEquals(result.includes("Admin reason:"), true)
  assertEquals(result.includes("family-friendly community event"), true)
  assertEquals(result.includes("Admin-overridden decisions are stronger signals"), true)
})

type QueryResponse = { data: unknown; error: Error | null }

interface QueryCall {
  kind: "rpc" | "query"
  target: string
  filters: Array<[string, unknown]>
  select?: string
  order?: { column: string; options?: { ascending?: boolean } }
}

function makeMemoryContextSupabase(
  similar: unknown[],
  responses: Record<string, QueryResponse>
): { supabase: SupabaseClient; calls: QueryCall[] } {
  const calls: QueryCall[] = []

  function query(table: string): Record<string, unknown> {
    const call: QueryCall = { kind: "query", target: table, filters: [] }
    calls.push(call)
    const response = responses[table] ?? { data: [], error: null }
    const builder = {
      select(columns: string) {
        call.select = columns
        return builder
      },
      in(column: string, values: unknown) {
        call.filters.push([column, values])
        return builder
      },
      eq(column: string, value: unknown) {
        call.filters.push([column, value])
        return builder
      },
      order(column: string, options?: { ascending?: boolean }) {
        call.order = { column, options }
        return builder
      },
      limit() {
        return builder
      },
      maybeSingle() {
        return Promise.resolve(response)
      },
      then<TResult1 = QueryResponse, TResult2 = never>(
        onfulfilled?: ((value: QueryResponse) => TResult1 | PromiseLike<TResult1>) | null,
        onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null
      ) {
        return Promise.resolve(response).then(onfulfilled, onrejected)
      },
    }
    return builder
  }

  return {
    calls,
    supabase: {
      rpc(name: string) {
        calls.push({ kind: "rpc", target: name, filters: [] })
        return Promise.resolve({ data: similar, error: null })
      },
      from(table: string) {
        return query(table)
      },
    } as unknown as SupabaseClient,
  }
}

const similarEvents = [
  { event_id: "evt-3", title: "Third event", cosine_distance: 0.03 },
  { event_id: "evt-1", title: "First event", cosine_distance: 0.1 },
  { event_id: "evt-5", title: "Fifth event", cosine_distance: 0.2 },
  { event_id: "evt-2", title: "Second event", cosine_distance: 0.25 },
  { event_id: "evt-4", title: "Fourth event", cosine_distance: 0.3 },
]

Deno.test("fetchSimilarEventTagContext bulk-loads tags and latest decisions in similarity order", async () => {
  const { supabase, calls } = makeMemoryContextSupabase(similarEvents, {
    event_tags: {
      data: [
        {
          event_id: "evt-1",
          tag_id: "ai-tag",
          confidence: 0.99,
          is_manual_override: false,
          tags: { slug: "ai", name: "AI" },
        },
        {
          event_id: "evt-3",
          tag_id: "low-tag",
          confidence: 0.4,
          is_manual_override: false,
          tags: { slug: "low", name: "Low" },
        },
        {
          event_id: "evt-3",
          tag_id: "admin-tag",
          confidence: 0.1,
          is_manual_override: true,
          tags: { slug: "admin", name: "Admin" },
        },
      ],
      error: null,
    },
    admin_event_decisions: {
      data: [
        {
          event_id: "evt-1",
          decision_type: "tag_edit",
          new_tags: [],
          reason: "newest evt-1 correction",
          created_at: "2026-07-24T12:00:00Z",
        },
        {
          event_id: "evt-3",
          decision_type: "status_and_tags",
          new_tags: [],
          reason: "latest evt-3 correction",
          created_at: "2026-07-24T11:00:00Z",
        },
        {
          event_id: "evt-1",
          decision_type: "tag_edit",
          new_tags: [],
          reason: "older evt-1 correction",
          created_at: "2026-07-24T10:00:00Z",
        },
      ],
      error: null,
    },
  })

  const contexts = await fetchSimilarEventTagContext(supabase, [0.1], null, null)

  assertEquals(calls.map((call) => call.target), [
    "find_similar_events",
    "event_tags",
    "admin_event_decisions",
  ])
  assertEquals(contexts.map((context) => context.eventId), similarEvents.map((event) => event.event_id))
  assertEquals(contexts[0].tags.map((tag) => tag.slug), ["admin", "low"])
  assertEquals(contexts[1].adminReason, "newest evt-1 correction")
  assertEquals(contexts[0].adminReason, "latest evt-3 correction")
  assertEquals(calls[1].filters, [["event_id", similarEvents.map((event) => event.event_id)]])
  assertEquals(calls[2].filters, [
    ["event_id", similarEvents.map((event) => event.event_id)],
    ["decision_type", ["tag_edit", "status_and_tags"]],
  ])
  assertEquals(calls[2].order, { column: "created_at", options: { ascending: false } })
})

Deno.test("fetchSimilarReviewContext bulk-loads review state and skips missing events", async () => {
  const { supabase, calls } = makeMemoryContextSupabase(similarEvents, {
    events: {
      data: [
        { id: "evt-2", status: "rejected", llm_review_decision: "reject" },
        { id: "evt-3", status: "published", llm_review_decision: "approve" },
        { id: "evt-1", status: "published", llm_review_decision: "approve" },
        { id: "evt-4", status: "published", llm_review_decision: "approve" },
      ],
      error: null,
    },
    admin_event_decisions: {
      data: [
        {
          event_id: "evt-1",
          decision_type: "status_change",
          new_status: "published",
          reason: "newest evt-1 status",
          created_at: "2026-07-24T12:00:00Z",
        },
        {
          event_id: "evt-3",
          decision_type: "status_change",
          new_status: "rejected",
          reason: "newest evt-3 status",
          created_at: "2026-07-24T11:00:00Z",
        },
        {
          event_id: "evt-1",
          decision_type: "status_change",
          new_status: "rejected",
          reason: "older evt-1 status",
          created_at: "2026-07-24T10:00:00Z",
        },
      ],
      error: null,
    },
  })

  const result = await fetchSimilarReviewContext(supabase, [0.1], null, null)

  assertEquals(calls.map((call) => call.target), [
    "find_similar_events",
    "events",
    "admin_event_decisions",
  ])
  assertEquals(result.contexts.map((context) => context.eventId), ["evt-3", "evt-1", "evt-2", "evt-4"])
  assertEquals(result.contexts[1].adminDecision, "published")
  assertEquals(result.contexts[0].adminDecision, "rejected")
  assertEquals(result.confidenceAdjustment, {
    delta: 0,
    reason: "mixed outcomes among similar events",
    approvedCount: 3,
    rejectedCount: 1,
    totalSimilar: 4,
  })
  assertEquals(calls[1].filters, [["id", similarEvents.map((event) => event.event_id)]])
  assertEquals(calls[2].filters, [
    ["decision_type", "status_change"],
    ["event_id", similarEvents.map((event) => event.event_id)],
  ])
  assertEquals(calls[2].order, { column: "created_at", options: { ascending: false } })
})

Deno.test("memory context returns established empty fallbacks and warns once for each bulk failure", async () => {
  const warningMessages: unknown[][] = []
  const originalWarn = console.warn
  console.warn = ((...args: unknown[]) => warningMessages.push(args)) as typeof console.warn

  try {
    for (const [helper, failingTable] of [
      ["tag", "event_tags"],
      ["tag", "admin_event_decisions"],
      ["review", "events"],
      ["review", "admin_event_decisions"],
    ] as const) {
      const { supabase } = makeMemoryContextSupabase(similarEvents, {
        event_tags: {
          data: [],
          error: failingTable === "event_tags" ? new Error("bulk tags failed") : null,
        },
        events: {
          data: [],
          error: failingTable === "events" ? new Error("bulk events failed") : null,
        },
        admin_event_decisions: {
          data: [],
          error:
            failingTable === "admin_event_decisions" ? new Error("bulk decisions failed") : null,
        },
      })

      if (helper === "tag") {
        assertEquals(await fetchSimilarEventTagContext(supabase, [0.1], null, null), [])
      } else {
        const result = await fetchSimilarReviewContext(supabase, [0.1], null, null)
        assertEquals(result.contexts, [])
        assertEquals(result.confidenceAdjustment.delta, 0)
        assertEquals(result.confidenceAdjustment.approvedCount, 0)
        assertEquals(result.confidenceAdjustment.rejectedCount, 0)
        assertEquals(result.confidenceAdjustment.totalSimilar, 0)
      }
    }
  } finally {
    console.warn = originalWarn
  }

  assertEquals(warningMessages.length, 4)
  assertEquals(
    warningMessages.map(([entry]) => JSON.parse(String(entry)).message),
    [
      "memory-context: failed to bulk fetch tags for similar events",
      "memory-context: failed to bulk fetch tag decisions for similar events",
      "memory-context: failed to bulk fetch review events",
      "memory-context: failed to bulk fetch review decisions",
    ]
  )
})
