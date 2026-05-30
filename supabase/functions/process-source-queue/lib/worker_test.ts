import { assertEquals } from "jsr:@std/assert";
import {
  planSourceQueueClaimHandling,
  processSourceQueueRow,
  shouldFallbackToLlm,
  sourceRetryDelayMinutes,
} from "./worker.ts";
import type {
  EventSourceRow,
  FetchedArtifact,
  ParsedEvent,
  SourceResult,
  SourceType,
} from "../../scrape-source/lib/types.ts";
import type { SourceParser } from "../../scrape-source/parsers/index.ts";

Deno.test("sourceRetryDelayMinutes uses bounded exponential backoff", () => {
  assertEquals(sourceRetryDelayMinutes(1), 5);
  assertEquals(sourceRetryDelayMinutes(2), 15);
  assertEquals(sourceRetryDelayMinutes(3), 60);
  assertEquals(sourceRetryDelayMinutes(4), null);
});

Deno.test("planSourceQueueClaimHandling starts one row and releases the rest", () => {
  assertEquals(planSourceQueueClaimHandling([1, 2, 3], 0), {
    start: 1,
    release: [2, 3],
  });
  assertEquals(planSourceQueueClaimHandling([1, 2], 120_000), {
    start: null,
    release: [1, 2],
  });
});

Deno.test("shouldFallbackToLlm only falls back in hybrid mode", () => {
  assertEquals(shouldFallbackToLlm("deterministic_then_llm", 0, null), true);
  assertEquals(shouldFallbackToLlm("deterministic_then_llm", 2, null), false);
  assertEquals(
    shouldFallbackToLlm("deterministic", 0, new Error("parser failed")),
    false,
  );
  assertEquals(shouldFallbackToLlm("llm", 0, null), false);
});

interface RpcCall {
  name: string;
  params?: Record<string, unknown>;
}

interface TableInsert {
  table: string;
  payload: unknown;
}

interface TableUpdate {
  table: string;
  payload: Record<string, unknown>;
}

function queueRow(
  overrides: Partial<Parameters<typeof processSourceQueueRow>[1]> = {},
) {
  return {
    id: 42,
    source_id: "source-1",
    source_run_id: null,
    attempt_count: 0,
    ...overrides,
  };
}

function source(overrides: Partial<EventSourceRow> = {}): EventSourceRow {
  return {
    id: "source-1",
    name: "Source",
    url: "https://example.com/events",
    source_type: "website",
    extraction_mode: "deterministic",
    processing_mode: "manual_review",
    city_id: null,
    is_active: true,
    auto_approve: false,
    scrape_interval_hours: 24,
    last_scraped_at: null,
    last_status: null,
    error_count: 0,
    date_window_days: null,
    ...overrides,
  };
}

function parsedEvent(overrides: Partial<ParsedEvent> = {}): ParsedEvent {
  return {
    title: "Story Time",
    description: "Books and songs",
    startDatetime: "2026-06-01T15:00:00.000Z",
    endDatetime: null,
    venueName: "Library",
    address: null,
    sourceUrl: "https://example.com/story-time",
    imageUrl: null,
    images: [],
    price: null,
    isFree: true,
    ...overrides,
  };
}

function parser(overrides: Partial<SourceParser> = {}): SourceParser {
  return {
    type: "website",
    label: "Website",
    fetchArtifact: () =>
      Promise.resolve({
        url: "https://example.com/events",
        contentType: "text/html",
        body: "<html></html>",
      }),
    extractEvents: () => Promise.resolve([parsedEvent()]),
    ...overrides,
  } as SourceParser;
}

function createDependencies(overrides: {
  parser?: SourceParser;
  importParsedSourceEvents?: (
    parsedEvents: ParsedEvent[],
  ) => Promise<SourceResult>;
  extractWithLlm?: () => Promise<{
    events: ParsedEvent[];
    config: {
      provider: string;
      model: string;
      baseUrl: string;
      apiKey: string;
      configured: boolean;
    };
    latencyMs: number;
  }>;
} = {}) {
  return {
    parsers: {
      website: overrides.parser ?? parser(),
      rss: parser({ type: "rss" }),
      ical: parser({ type: "ical" }),
      manual: parser({ type: "manual" }),
      macaronikid: parser({ type: "macaronikid" }),
      brec: parser({ type: "brec" }),
      downtownlafayette: parser({ type: "downtownlafayette" }),
      lcglafayette: parser({ type: "lcglafayette" }),
      localhop: parser({ type: "localhop" }),
    } as Record<SourceType, SourceParser>,
    importParsedSourceEvents: (
      _supabase: unknown,
      sourceRow: EventSourceRow,
      _runId: string,
      parsedEvents: ParsedEvent[],
    ) =>
      overrides.importParsedSourceEvents?.(parsedEvents) ??
        Promise.resolve({
          sourceId: sourceRow.id,
          status: "success",
          eventsFound: parsedEvents.length,
          eventsImported: parsedEvents.length,
          eventsSkipped: 0,
          error: null,
        }),
    extractWithLlm: () =>
      overrides.extractWithLlm?.() ??
        Promise.resolve({
          events: [parsedEvent({ title: "LLM Event" })],
          config: {
            provider: "test",
            model: "test-model",
            baseUrl: "https://llm.test",
            apiKey: "test",
            configured: true,
          },
          latencyMs: 12,
        }),
  };
}

function createFakeSupabase(sourceRow: EventSourceRow | null = source()) {
  const rpcCalls: RpcCall[] = [];
  const inserts: TableInsert[] = [];
  const updates: TableUpdate[] = [];

  const client = {
    rpc(name: string, params?: Record<string, unknown>) {
      rpcCalls.push({ name, params });
      if (name === "mark_source_scrape_queue_started") {
        return Promise.resolve({
          data: { ...queueRow(), attempt_count: 1 },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: null });
    },
    from(table: string) {
      const builder = {
        error: null,
        select() {
          return builder;
        },
        insert(payload: unknown) {
          inserts.push({ table, payload });
          return builder;
        },
        update(payload: Record<string, unknown>) {
          updates.push({ table, payload });
          return builder;
        },
        eq() {
          return builder;
        },
        maybeSingle() {
          if (table === "event_sources") {
            return Promise.resolve({ data: sourceRow, error: null });
          }
          return Promise.resolve({ data: null, error: null });
        },
        single() {
          return Promise.resolve({ data: { id: "run-1" }, error: null });
        },
      };
      return builder;
    },
  };

  return { client, rpcCalls, inserts, updates };
}

Deno.test("processSourceQueueRow skips rows without a source id", async () => {
  const db = createFakeSupabase();

  const result = await processSourceQueueRow(
    db.client as never,
    queueRow({ source_id: null }),
    createDependencies(),
  );

  assertEquals(result, { outcome: "skipped", imported: 0 });
  assertEquals(db.rpcCalls, [
    {
      name: "mark_source_scrape_queue_skipped",
      params: {
        p_queue_id: 42,
        p_skip_reason: "source missing from queue row",
      },
    },
  ]);
});

Deno.test("processSourceQueueRow skips deleted and disabled sources", async (t) => {
  await t.step("deleted", async () => {
    const db = createFakeSupabase(null);
    const result = await processSourceQueueRow(
      db.client as never,
      queueRow(),
      createDependencies(),
    );
    assertEquals(result, { outcome: "skipped", imported: 0 });
    assertEquals(db.rpcCalls.at(-1), {
      name: "mark_source_scrape_queue_skipped",
      params: {
        p_queue_id: 42,
        p_skip_reason: "source deleted before processing",
      },
    });
  });

  await t.step("disabled", async () => {
    const db = createFakeSupabase(source({ is_active: false }));
    const result = await processSourceQueueRow(
      db.client as never,
      queueRow(),
      createDependencies(),
    );
    assertEquals(result, { outcome: "skipped", imported: 0 });
    assertEquals(db.rpcCalls.at(-1), {
      name: "mark_source_scrape_queue_skipped",
      params: {
        p_queue_id: 42,
        p_skip_reason: "source disabled before processing",
      },
    });
  });
});

Deno.test("processSourceQueueRow marks successful deterministic imports succeeded", async () => {
  const db = createFakeSupabase();
  let processedEvents: ParsedEvent[] = [];

  const result = await processSourceQueueRow(
    db.client as never,
    queueRow(),
    createDependencies({
      importParsedSourceEvents: (events) => {
        processedEvents = events;
        return Promise.resolve({
          sourceId: "source-1",
          status: "success",
          eventsFound: events.length,
          eventsImported: 1,
          eventsSkipped: 0,
          error: null,
        });
      },
    }),
  );

  assertEquals(result, { outcome: "succeeded", imported: 1 });
  assertEquals(processedEvents.map((event) => event.title), ["Story Time"]);
  assertEquals(
    db.updates.some((update) =>
      update.table === "source_scrape_queue" &&
      update.payload.status === "succeeded" &&
      update.payload.last_error === null
    ),
    true,
  );
});

Deno.test("processSourceQueueRow schedules retry when parser fetch fails", async () => {
  const db = createFakeSupabase();

  const result = await processSourceQueueRow(
    db.client as never,
    queueRow(),
    createDependencies({
      parser: parser({
        fetchArtifact: () => Promise.reject(new Error("fetch failed")),
      }),
    }),
  );

  assertEquals(result, { outcome: "retry", imported: 0 });
  assertEquals(db.inserts.at(-1)?.table, "source_extraction_traces");
  assertEquals(db.updates.at(-1)?.payload.status, "error");
  assertEquals(db.rpcCalls.at(-1), {
    name: "source_scrape_queue_schedule_retry",
    params: {
      p_queue_id: 42,
      p_attempt_count: 1,
      p_error: "fetch failed",
    },
  });
});

Deno.test("processSourceQueueRow schedules retry when deterministic extraction returns no events", async () => {
  const db = createFakeSupabase(source({ extraction_mode: "deterministic" }));

  const result = await processSourceQueueRow(
    db.client as never,
    queueRow(),
    createDependencies({
      parser: parser({ extractEvents: () => Promise.resolve([]) }),
    }),
  );

  assertEquals(result, { outcome: "retry", imported: 0 });
  assertEquals(
    (db.inserts.at(-1)?.payload as { status?: string }).status,
    "fallback",
  );
  assertEquals(db.rpcCalls.at(-1)?.name, "source_scrape_queue_schedule_retry");
});

Deno.test("processSourceQueueRow records deterministic-to-LLM fallback traces", async () => {
  const db = createFakeSupabase(
    source({ extraction_mode: "deterministic_then_llm" }),
  );

  const result = await processSourceQueueRow(
    db.client as never,
    queueRow(),
    createDependencies({
      parser: parser({ extractEvents: () => Promise.resolve([]) }),
    }),
  );

  assertEquals(result, { outcome: "succeeded", imported: 1 });
  assertEquals(
    db.inserts
      .filter((insert) => insert.table === "source_extraction_traces")
      .map((insert) =>
        (insert.payload as { extractor?: string; status?: string }).status
      ),
    ["fallback", "success"],
  );
  assertEquals(
    (db.inserts.at(-1)?.payload as {
      extractor?: string;
      fallback_reason?: string;
    }).extractor,
    "llm",
  );
  assertEquals(
    (db.inserts.at(-1)?.payload as { fallback_reason?: string })
      .fallback_reason,
    "deterministic extractor returned no events",
  );
});
