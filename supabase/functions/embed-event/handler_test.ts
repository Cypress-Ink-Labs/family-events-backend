import { assertEquals, assertRejects } from "jsr:@std/assert";
import {
  embedEvent,
  EmbedEventRequestError,
  EmbedEventUpstreamError,
  generateEmbedding,
  handleEmbedEventRequest,
} from "./handler.ts";

// ── Mock helpers ─────────────────────────────────────────────────────────────

function makeFakeEmbedding(dims = 1536): number[] {
  return Array.from({ length: dims }, (_, i) => Math.sin(i * 0.01));
}

function makeMockFetch(
  embedding: number[] = makeFakeEmbedding(),
  promptTokens = 42,
  totalTokens = 42,
): typeof fetch {
  return async (_url: string | URL | Request, _init?: RequestInit) => {
    return new Response(
      JSON.stringify({
        object: "list",
        data: [{ object: "embedding", embedding, index: 0 }],
        model: "text-embedding-3-small",
        usage: { prompt_tokens: promptTokens, total_tokens: totalTokens },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };
}

function makeMockFetchError(status: number, body: string): typeof fetch {
  return async () => {
    return new Response(body, { status });
  };
}

function makeMockFetchBadDimensions(): typeof fetch {
  return async () => {
    return new Response(
      JSON.stringify({
        data: [{ embedding: [0.1, 0.2, 0.3], index: 0 }],
        model: "text-embedding-3-small",
        usage: { prompt_tokens: 5, total_tokens: 5 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };
}

class FakeSupabase {
  embeddings = new Map<string, { embedding: string; model: string }>();
  events = new Map<string, { title: string; description: string | null }>();

  from(table: string) {
    return new FakeQuery(this, table);
  }
}

class FakeQuery {
  private supabase: FakeSupabase;
  private table: string;
  private filters: Record<string, string> = {};
  private _single = false;

  constructor(supabase: FakeSupabase, table: string) {
    this.supabase = supabase;
    this.table = table;
  }

  select(_columns?: string) {
    return this;
  }

  eq(column: string, value: string) {
    this.filters[column] = value;
    return this;
  }

  maybeSingle() {
    this._single = true;
    if (this.table === "events") {
      const event = this.supabase.events.get(this.filters["id"] ?? "");
      return Promise.resolve({ data: event ?? null, error: null });
    }
    return Promise.resolve({ data: null, error: null });
  }

  upsert(data: Record<string, unknown>, _options?: Record<string, unknown>) {
    if (this.table === "event_embeddings") {
      const eventId = data.event_id as string;
      this.supabase.embeddings.set(eventId, {
        embedding: data.embedding as string,
        model: data.model as string,
      });
    }
    return Promise.resolve({ data: null, error: null });
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

Deno.test("generateEmbedding - returns valid embedding from mocked OpenAI", async () => {
  const expectedEmbedding = makeFakeEmbedding();
  const result = await generateEmbedding(
    "Test event title",
    "fake-api-key",
    makeMockFetch(expectedEmbedding, 10, 10),
  );

  assertEquals(result.embedding.length, 1536);
  assertEquals(result.embedding, expectedEmbedding);
  assertEquals(result.usage.promptTokens, 10);
  assertEquals(result.usage.totalTokens, 10);
});

Deno.test("generateEmbedding - throws on OpenAI API error", async () => {
  await assertRejects(
    () =>
      generateEmbedding(
        "Test event",
        "fake-api-key",
        makeMockFetchError(429, "rate limited"),
      ),
    EmbedEventUpstreamError,
    "OpenAI embeddings failed (429)",
  );
});

Deno.test("generateEmbedding - throws on wrong dimensions", async () => {
  await assertRejects(
    () =>
      generateEmbedding(
        "Test event",
        "fake-api-key",
        makeMockFetchBadDimensions(),
      ),
    Error,
    "unexpected embedding dimensions: 3",
  );
});

Deno.test("embedEvent - generates and stores embedding", async () => {
  const fakeSupabase = new FakeSupabase();
  const result = await embedEvent(
    {
      event_id: "evt-123",
      title: "Kids Art Workshop",
      description: "Fun painting for ages 3-8",
    },
    {
      supabase:
        fakeSupabase as unknown as import("@supabase/supabase-js").SupabaseClient,
      openAiApiKey: "fake-key",
      fetchImpl: makeMockFetch(),
    },
  );

  assertEquals(result.event_id, "evt-123");
  assertEquals(result.model, "text-embedding-3-small");
  assertEquals(result.dimensions, 1536);
  assertEquals(result.stored, true);
  assertEquals(typeof result.processing_ms, "number");

  // Verify embedding was stored in fake DB
  const stored = fakeSupabase.embeddings.get("evt-123");
  assertEquals(stored?.model, "text-embedding-3-small");
  assertEquals(stored?.embedding?.startsWith("["), true);
});

Deno.test("embedEvent - truncates long description", async () => {
  const fakeSupabase = new FakeSupabase();
  const longDescription = "x".repeat(5000);
  let capturedInput = "";

  const mockFetch: typeof fetch = async (
    input: string | URL | Request,
    init?: RequestInit,
  ) => {
    // Extract the body from the request to inspect it
    if (init && typeof init.body === "string") {
      capturedInput = init.body;
    } else if (input instanceof Request) {
      capturedInput = await input.text();
    }
    return new Response(
      JSON.stringify({
        data: [{ embedding: makeFakeEmbedding(), index: 0 }],
        model: "text-embedding-3-small",
        usage: { prompt_tokens: 100, total_tokens: 100 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };

  await embedEvent(
    {
      event_id: "evt-long",
      title: "Short title",
      description: longDescription,
    },
    {
      supabase:
        fakeSupabase as unknown as import("@supabase/supabase-js").SupabaseClient,
      openAiApiKey: "fake-key",
      fetchImpl: mockFetch,
    },
  );

  // The input sent to OpenAI should be truncated to MAX_INPUT_CHARS (2000)
  const parsed = JSON.parse(capturedInput);
  assertEquals(typeof parsed.input, "string");
  assertEquals(parsed.input.length <= 2000, true);
});

Deno.test("handleEmbedEventRequest - requires event_id", async () => {
  const fakeSupabase = new FakeSupabase();
  await assertRejects(
    () =>
      handleEmbedEventRequest({}, {
        supabase:
          fakeSupabase as unknown as import("@supabase/supabase-js").SupabaseClient,
        openAiApiKey: "fake-key",
      }),
    EmbedEventRequestError,
    "event_id is required",
  );
});

Deno.test("handleEmbedEventRequest - fetches event from DB when no title provided", async () => {
  const fakeSupabase = new FakeSupabase();
  fakeSupabase.events.set("evt-db", {
    title: "Music Festival",
    description: "Family-friendly music in the park",
  });

  const result = await handleEmbedEventRequest(
    { event_id: "evt-db" },
    {
      supabase:
        fakeSupabase as unknown as import("@supabase/supabase-js").SupabaseClient,
      openAiApiKey: "fake-key",
      fetchImpl: makeMockFetch(),
    },
  );

  assertEquals(result.event_id, "evt-db");
  assertEquals(result.stored, true);
});

Deno.test("handleEmbedEventRequest - 404 when event not found in DB", async () => {
  const fakeSupabase = new FakeSupabase();
  await assertRejects(
    () =>
      handleEmbedEventRequest(
        { event_id: "evt-missing" },
        {
          supabase:
            fakeSupabase as unknown as import("@supabase/supabase-js").SupabaseClient,
          openAiApiKey: "fake-key",
        },
      ),
    EmbedEventRequestError,
    "event not found",
  );
});

Deno.test("embedEvent - upserts on re-embed", async () => {
  const fakeSupabase = new FakeSupabase();
  const deps = {
    supabase:
      fakeSupabase as unknown as import("@supabase/supabase-js").SupabaseClient,
    openAiApiKey: "fake-key",
    fetchImpl: makeMockFetch(),
  };

  // First embed
  await embedEvent(
    { event_id: "evt-re", title: "Original title" },
    deps,
  );
  const first = fakeSupabase.embeddings.get("evt-re");

  // Re-embed with different title
  await embedEvent(
    { event_id: "evt-re", title: "Updated title" },
    deps,
  );
  const second = fakeSupabase.embeddings.get("evt-re");

  // Both should succeed (upsert), stored model should be same
  assertEquals(first?.model, "text-embedding-3-small");
  assertEquals(second?.model, "text-embedding-3-small");
});
