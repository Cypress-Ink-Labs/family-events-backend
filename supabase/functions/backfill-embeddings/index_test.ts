import { assertEquals } from "jsr:@std/assert";
import { backfillEmbeddings } from "./index.ts";

// ── Mock helpers ─────────────────────────────────────────────────────────────

function makeFakeEmbedding(dims = 1536): number[] {
  return Array.from({ length: dims }, (_, i) => Math.sin(i * 0.01));
}

function makeMockFetch(): typeof fetch {
  return async () => {
    return new Response(
      JSON.stringify({
        data: [{ embedding: makeFakeEmbedding(), index: 0 }],
        model: "text-embedding-3-small",
        usage: { prompt_tokens: 20, total_tokens: 20 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };
}

interface FakeEvent {
  id: string;
  title: string;
  description: string | null;
  created_at: string;
}

class FakeSupabase {
  events: FakeEvent[] = [];
  embeddings = new Map<string, { event_id: string; embedding: string; model: string }>();
  embeddingRows: Array<{ event_id: string }> = [];

  from(table: string) {
    return new FakeQuery(this, table);
  }
}

class FakeQuery {
  private supabase: FakeSupabase;
  private table: string;
  private _selectCols = "";
  private _orderCol = "";
  private _orderAsc = true;
  private _limit = 1000;
  private _notCol = "";
  private _notOp = "";
  private _notVal = "";

  constructor(supabase: FakeSupabase, table: string) {
    this.supabase = supabase;
    this.table = table;
  }

  select(columns?: string) {
    this._selectCols = columns ?? "*";
    return this;
  }

  order(column: string, opts?: { ascending?: boolean }) {
    this._orderCol = column;
    this._orderAsc = opts?.ascending ?? true;
    return this;
  }

  limit(n: number) {
    this._limit = n;
    return this;
  }

  not(column: string, operator: string, value: string) {
    this._notCol = column;
    this._notOp = operator;
    this._notVal = value;
    return this;
  }

  upsert(data: Record<string, unknown>, _options?: Record<string, unknown>) {
    if (this.table === "event_embeddings") {
      const eventId = data.event_id as string;
      this.supabase.embeddings.set(eventId, {
        event_id: eventId,
        embedding: data.embedding as string,
        model: data.model as string,
      });
    }
    return Promise.resolve({ data: null, error: null });
  }

  then(resolve: (val: { data: unknown; error: null }) => void) {
    if (this.table === "event_embeddings") {
      // Return existing embedding event_ids
      resolve({ data: this.supabase.embeddingRows, error: null });
    } else if (this.table === "events") {
      // Filter out already-embedded events
      const excludeIds = new Set(
        this._notVal
          ? this._notVal.replace(/[()]/g, "").split(",").filter(Boolean)
          : [],
      );
      const filtered = this.supabase.events
        .filter((e) => !excludeIds.has(e.id))
        .slice(0, this._limit);
      resolve({ data: filtered, error: null });
    } else {
      resolve({ data: [], error: null });
    }
    return this;
  }

  catch() {
    return this;
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

Deno.test("backfillEmbeddings - processes events without embeddings", async () => {
  const fake = new FakeSupabase();
  fake.events = [
    { id: "evt-1", title: "Kids Music Class", description: "Fun for all ages", created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Art Workshop", description: null, created_at: "2026-01-02T00:00:00Z" },
  ];
  fake.embeddingRows = []; // none embedded yet

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, fetchImpl: makeMockFetch() },
  );

  assertEquals(result.total_found, 2);
  assertEquals(result.processed, 2);
  assertEquals(result.failed, 0);
  assertEquals(result.skipped, 0);
  assertEquals(fake.embeddings.size, 2);
});

Deno.test("backfillEmbeddings - skips events without title", async () => {
  const fake = new FakeSupabase();
  fake.events = [
    { id: "evt-1", title: "", description: null, created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Valid Event", description: "desc", created_at: "2026-01-02T00:00:00Z" },
  ];
  fake.embeddingRows = [];

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, fetchImpl: makeMockFetch() },
  );

  assertEquals(result.total_found, 2);
  assertEquals(result.processed, 1);
  assertEquals(result.skipped, 1);
});

Deno.test("backfillEmbeddings - returns early when nothing to do", async () => {
  const fake = new FakeSupabase();
  fake.events = [];
  fake.embeddingRows = [];

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0 },
  );

  assertEquals(result.total_found, 0);
  assertEquals(result.processed, 0);
});

Deno.test("backfillEmbeddings - respects budget", async () => {
  const fake = new FakeSupabase();
  fake.events = [
    { id: "evt-1", title: "Event 1", description: null, created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Event 2", description: null, created_at: "2026-01-02T00:00:00Z" },
    { id: "evt-3", title: "Event 3", description: null, created_at: "2026-01-03T00:00:00Z" },
  ];
  fake.embeddingRows = [];

  let callCount = 0;
  // Simulate time passing: first call at t=0, subsequent at t > budget
  const now = () => {
    callCount++;
    // After first event processed, exhaust budget
    return callCount <= 2 ? 0 : 120_000;
  };

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, budgetMs: 110_000, now, fetchImpl: makeMockFetch() },
  );

  assertEquals(result.total_found, 3);
  // Should have processed at least 1 before budget kicked in
  assertEquals(result.processed >= 1, true);
  assertEquals(result.processed < 3, true);
});

Deno.test("backfillEmbeddings - handles embedding failures gracefully", async () => {
  const fake = new FakeSupabase();
  fake.events = [
    { id: "evt-1", title: "Event 1", description: null, created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Event 2", description: null, created_at: "2026-01-02T00:00:00Z" },
  ];
  fake.embeddingRows = [];

  let callNum = 0;
  const failingFetch: typeof fetch = async () => {
    callNum++;
    if (callNum === 1) {
      return new Response("rate limited", { status: 429 });
    }
    return new Response(
      JSON.stringify({
        data: [{ embedding: makeFakeEmbedding(), index: 0 }],
        model: "text-embedding-3-small",
        usage: { prompt_tokens: 10, total_tokens: 10 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, fetchImpl: failingFetch },
  );

  assertEquals(result.total_found, 2);
  assertEquals(result.failed, 1);
  assertEquals(result.processed, 1);
});

Deno.test("backfillEmbeddings - excludes already-embedded events", async () => {
  const fake = new FakeSupabase();
  fake.events = [
    { id: "evt-1", title: "Already Embedded", description: null, created_at: "2026-01-01T00:00:00Z" },
    { id: "evt-2", title: "Needs Embedding", description: null, created_at: "2026-01-02T00:00:00Z" },
  ];
  fake.embeddingRows = [{ event_id: "evt-1" }]; // evt-1 already has embedding

  const result = await backfillEmbeddings(
    fake as unknown as import("@supabase/supabase-js").SupabaseClient,
    "fake-api-key",
    { batchSize: 10, delayMs: 0, fetchImpl: makeMockFetch() },
  );

  assertEquals(result.total_found, 1);
  assertEquals(result.processed, 1);
  assertEquals(fake.embeddings.has("evt-2"), true);
  assertEquals(fake.embeddings.has("evt-1"), false);
});
