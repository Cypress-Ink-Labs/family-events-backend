import { assertEquals } from "jsr:@std/assert"
import { backfillEmbeddings } from "./index.ts"

// ── Mock helpers ─────────────────────────────────────────────────────────────

function makeFakeEmbedding(dims = 1536): number[] {
  return Array.from({ length: dims }, (_, i) => Math.sin(i * 0.01))
}

function makeMockFetch(): typeof fetch {
  return async () => {
    return new Response(
      JSON.stringify({
        data: [{ embedding: makeFakeEmbedding(), index: 0 }],
        model: "text-embedding-3-small",
        usage: { prompt_tokens: 20, total_tokens: 20 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    )
  }
}

interface FakeEvent {
  id: string
  title: string
  description: string | null
  created_at: string
}

class FakeSupabase {
  events: FakeEvent[] = []
  embeddings = new Map<string, { event_id: string; embedding: string; model: string }>()
  // rpc call log: records each call for assertion
  rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []

  rpc(fn: string, args: Record<string, unknown> = {}) {
    this.rpcCalls.push({ fn, args })
    if (fn === "list_events_needing_embeddings") {
      const limit = (args.p_limit as number) ?? 50
      const data = this.events.slice(0, limit)
      return Promise.resolve({ data, error: null })
    }
    return Promise.resolve({ data: [], error: null })
  }

  from(table: string) {
    return new FakeQuery(this, table)
  }
}

class FakeQuery {
  private supabase: FakeSupabase
  private table: string

  constructor(supabase: FakeSupabase, table: string) {
    this.supabase = supabase
    this.table = table
  }

  upsert(data: Record<string, unknown>, _options?: Record<string, unknown>) {
    if (this.table === "event_embeddings") {
      const eventId = data.event_id as string
      this.supabase.embeddings.set(eventId, {
        event_id: eventId,
        embedding: data.embedding as string,
        model: data.model as string,
      })
    }
    return Promise.resolve({ data: null, error: null })
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

Deno.test("backfillEmbeddings - processes events without embeddings", async () => {
  const fake = new FakeSupabase()
  fake.events = [
    {
      id: "evt-1",
      title: "Kids Music Class",
      description: "Fun for all ages",
      created_at: "2026-01-01T00:00:00Z",
    },
    { id: "evt-2", title: "Art Workshop", description: null, created_at: "2026-01-02T00:00:00Z" },
  ]

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, fetchImpl: makeMockFetch() }
  )

  assertEquals(result.total_found, 2)
  assertEquals(result.processed, 2)
  assertEquals(result.failed, 0)
  assertEquals(result.skipped, 0)
  assertEquals(fake.embeddings.size, 2)

  // Verify RPC was called with the correct argument
  assertEquals(fake.rpcCalls.length, 1)
  assertEquals(fake.rpcCalls[0].fn, "list_events_needing_embeddings")
  assertEquals(fake.rpcCalls[0].args, { p_limit: 10 })
})

Deno.test("backfillEmbeddings - skips events without title", async () => {
  const fake = new FakeSupabase()
  fake.events = [
    { id: "evt-1", title: "", description: null, created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Valid Event", description: "desc", created_at: "2026-01-02T00:00:00Z" },
  ]

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, fetchImpl: makeMockFetch() }
  )

  assertEquals(result.total_found, 2)
  assertEquals(result.processed, 1)
  assertEquals(result.skipped, 1)
})

Deno.test("backfillEmbeddings - returns early when nothing to do", async () => {
  const fake = new FakeSupabase()
  fake.events = []

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0 }
  )

  assertEquals(result.total_found, 0)
  assertEquals(result.processed, 0)
})

Deno.test("backfillEmbeddings - respects budget", async () => {
  const fake = new FakeSupabase()
  fake.events = [
    { id: "evt-1", title: "Event 1", description: null, created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Event 2", description: null, created_at: "2026-01-02T00:00:00Z" },
    { id: "evt-3", title: "Event 3", description: null, created_at: "2026-01-03T00:00:00Z" },
  ]

  let callCount = 0
  // Simulate time passing: first call at t=0, subsequent at t > budget
  const now = () => {
    callCount++
    // After first event processed, exhaust budget
    return callCount <= 2 ? 0 : 120_000
  }

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, budgetMs: 110_000, now, fetchImpl: makeMockFetch() }
  )

  assertEquals(result.total_found, 3)
  // Should have processed at least 1 before budget kicked in
  assertEquals(result.processed >= 1, true)
  assertEquals(result.processed < 3, true)
})

Deno.test("backfillEmbeddings - handles embedding failures gracefully", async () => {
  const fake = new FakeSupabase()
  fake.events = [
    { id: "evt-1", title: "Event 1", description: null, created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Event 2", description: null, created_at: "2026-01-02T00:00:00Z" },
  ]

  let callNum = 0
  const failingFetch: typeof fetch = async () => {
    callNum++
    if (callNum === 1) {
      return new Response("rate limited", { status: 429 })
    }
    return new Response(
      JSON.stringify({
        data: [{ embedding: makeFakeEmbedding(), index: 0 }],
        model: "text-embedding-3-small",
        usage: { prompt_tokens: 10, total_tokens: 10 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    )
  }

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, fetchImpl: failingFetch }
  )

  assertEquals(result.total_found, 2)
  assertEquals(result.failed, 1)
  assertEquals(result.processed, 1)
})

Deno.test("backfillEmbeddings - RPC called with correct p_limit", async () => {
  const fake = new FakeSupabase()
  fake.events = [
    {
      id: "evt-1",
      title: "Already Embedded (handled server-side)",
      description: null,
      created_at: "2026-01-01T00:00:00Z",
    },
    {
      id: "evt-2",
      title: "Needs Embedding",
      description: null,
      created_at: "2026-01-02T00:00:00Z",
    },
  ]

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 25, delayMs: 0, fetchImpl: makeMockFetch() }
  )

  // The RPC is responsible for filtering; the fake returns all events
  assertEquals(result.total_found, 2)
  assertEquals(result.processed, 2)

  // Key assertion: RPC called with the batch size as p_limit
  assertEquals(fake.rpcCalls.length, 1)
  assertEquals(fake.rpcCalls[0].fn, "list_events_needing_embeddings")
  assertEquals(fake.rpcCalls[0].args, { p_limit: 25 })

  assertEquals(fake.embeddings.has("evt-1"), true)
  assertEquals(fake.embeddings.has("evt-2"), true)
})
