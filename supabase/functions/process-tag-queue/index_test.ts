import { assert, assertEquals } from "jsr:@std/assert";
import { processTagQueueBatch } from "./index.ts";

type QueueRow = {
  id: number;
  event_id: string;
  source_run_id: string | null;
  trigger_type: "import" | "reclassify" | "manual-review";
  attempt_count: number;
};

type EventRow = { title: string | null; description: string | null };

class FakeSupabase {
  reaped = 0;
  claimedRows: QueueRow[] = [];
  startedAttempts = new Map<number, number>();
  events = new Map<string, EventRow>();
  pendingCount = 0;
  rpcCalls: Array<{ name: string; args?: Record<string, unknown> }> = [];
  updates = new Map<number, Record<string, unknown>>();

  rpc(name: string, args?: Record<string, unknown>) {
    this.rpcCalls.push({ name, args });

    if (name === "reap_stuck_tag_queue_rows") {
      return Promise.resolve({ data: this.reaped, error: null });
    }

    if (name === "claim_tag_queue_batch") {
      return Promise.resolve({ data: this.claimedRows, error: null });
    }

    if (name === "mark_tag_queue_row_started") {
      const id = Number(args?.p_queue_id);
      const row = this.claimedRows.find((candidate) => candidate.id === id);
      return Promise.resolve({
        data: {
          ...(row ?? {}),
          attempt_count: this.startedAttempts.get(id) ??
            ((row?.attempt_count ?? 0) + 1),
        },
        error: null,
      });
    }

    if (
      name === "release_unstarted_tag_queue_rows" ||
      name === "invoke_process_tag_queue"
    ) {
      return Promise.resolve({ data: null, error: null });
    }

    throw new Error(`Unhandled rpc: ${name}`);
  }

  from(table: string) {
    return new FakeQuery(this, table);
  }

  rpcNames() {
    return this.rpcCalls.map((call) => call.name);
  }
}

class FakeQuery {
  private operation: "select" | "update" = "select";
  private filters = new Map<string, unknown>();
  private payload: Record<string, unknown> | null = null;

  constructor(
    private readonly db: FakeSupabase,
    private readonly table: string,
  ) {}

  select(_columns?: string, _options?: unknown) {
    this.operation = "select";
    return this;
  }

  update(payload: Record<string, unknown>) {
    this.operation = "update";
    this.payload = payload;
    return this;
  }

  eq(column: string, value: unknown) {
    this.filters.set(column, value);
    return this;
  }

  maybeSingle() {
    return this.execute(true);
  }

  then<TResult1 = unknown, TResult2 = never>(
    onfulfilled?: ((value: unknown) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.execute(false).then(onfulfilled, onrejected);
  }

  private execute(_expectSingle: boolean) {
    if (this.operation === "select" && this.table === "events") {
      const event = this.db.events.get(String(this.filters.get("id"))) ?? null;
      return Promise.resolve({ data: event, error: null });
    }

    if (this.operation === "select" && this.table === "event_tag_queue") {
      return Promise.resolve({
        data: null,
        count: this.db.pendingCount,
        error: null,
      });
    }

    if (this.operation === "update" && this.table === "event_tag_queue") {
      const id = Number(this.filters.get("id"));
      this.db.updates.set(id, this.payload ?? {});
      return Promise.resolve({ data: null, error: null });
    }

    throw new Error(`Unhandled query: ${this.operation} ${this.table}`);
  }
}

function row(
  id: number,
  overrides: Partial<QueueRow> = {},
): QueueRow {
  return {
    id,
    event_id: `evt-${id}`,
    source_run_id: `run-${id}`,
    trigger_type: "import",
    attempt_count: 0,
    ...overrides,
  };
}

async function withFetch(
  fakeFetch: typeof fetch,
  fn: () => Promise<void>,
) {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fakeFetch;
  try {
    await fn();
  } finally {
    globalThis.fetch = originalFetch;
  }
}

Deno.test("processTagQueueBatch returns after an empty claim", async () => {
  const db = new FakeSupabase();
  db.reaped = 2;

  const summary = await processTagQueueBatch(
    db as never,
    "http://local",
    "key",
  );

  assertEquals(summary.claimed, 0);
  assertEquals(summary.reaped, 2);
  assertEquals(summary.pending_after, null);
  assertEquals(db.rpcNames(), [
    "reap_stuck_tag_queue_rows",
    "claim_tag_queue_batch",
  ]);
});

Deno.test("processTagQueueBatch tags a claimed row and self-chains when work remains", async () => {
  const db = new FakeSupabase();
  db.claimedRows = [row(1)];
  db.events.set("evt-1", { title: "Storytime", description: "Books" });
  db.pendingCount = 3;
  const requests: Array<{ input: URL | RequestInfo; init?: RequestInit }> = [];

  await withFetch((input, init) => {
    requests.push({ input, init });
    return Promise.resolve(new Response("ok"));
  }, async () => {
    const summary = await processTagQueueBatch(
      db as never,
      "http://local",
      "service-key",
    );

    assertEquals(summary.claimed, 1);
    assertEquals(summary.succeeded, 1);
    assertEquals(summary.failed, 0);
    assertEquals(summary.dead, 0);
  });

  assertEquals(requests.length, 1);
  assertEquals(
    String(requests[0].input),
    "http://local/functions/v1/tag-event",
  );
  assertEquals(
    new Headers(requests[0].init?.headers).get("Authorization"),
    "Bearer service-key",
  );
  assertEquals(db.updates.get(1)?.status, "succeeded");
  assert(db.rpcNames().includes("invoke_process_tag_queue"));
});

Deno.test("processTagQueueBatch treats missing titles as soft success", async () => {
  const db = new FakeSupabase();
  db.claimedRows = [row(1)];
  db.events.set("evt-1", { title: "", description: "No usable title" });
  let fetchCount = 0;

  await withFetch(() => {
    fetchCount += 1;
    return Promise.resolve(new Response("should not be called"));
  }, async () => {
    const summary = await processTagQueueBatch(
      db as never,
      "http://local",
      "key",
    );

    assertEquals(summary.succeeded, 1);
    assertEquals(summary.failed, 0);
  });

  assertEquals(fetchCount, 0);
  assertEquals(db.updates.get(1)?.status, "succeeded");
});

Deno.test("processTagQueueBatch schedules retry with backoff fields after transient failure", async () => {
  const db = new FakeSupabase();
  db.claimedRows = [row(1)];
  db.startedAttempts.set(1, 2);
  db.events.set("evt-1", { title: "Storytime", description: "Books" });
  db.pendingCount = 4;

  await withFetch(
    () => Promise.resolve(new Response("upstream", { status: 503 })),
    async () => {
      const summary = await processTagQueueBatch(
        db as never,
        "http://local",
        "key",
      );

      assertEquals(summary.failed, 1);
      assertEquals(summary.dead, 0);
    },
  );

  const update = db.updates.get(1);
  assertEquals(update?.status, "pending");
  assertEquals(update?.started_at, null);
  assert(String(update?.last_error).includes("tag-event 503"));
  assert(typeof update?.next_attempt_at === "string");
  assert(!db.rpcNames().includes("invoke_process_tag_queue"));
});

Deno.test("processTagQueueBatch dead-letters exhausted rows", async () => {
  const db = new FakeSupabase();
  db.claimedRows = [row(1)];
  db.startedAttempts.set(1, 5);
  db.events.set("evt-1", { title: "Storytime", description: "Books" });

  await withFetch(() => Promise.reject(new Error("timeout")), async () => {
    const summary = await processTagQueueBatch(
      db as never,
      "http://local",
      "key",
    );

    assertEquals(summary.failed, 0);
    assertEquals(summary.dead, 1);
  });

  const update = db.updates.get(1);
  assertEquals(update?.status, "dead");
  assert(String(update?.last_error).includes("timeout"));
  assert(typeof update?.finished_at === "string");
});

Deno.test("processTagQueueBatch releases unstarted rows when the wall budget is nearly spent", async () => {
  const db = new FakeSupabase();
  db.claimedRows = [row(1), row(2), row(3), row(4), row(5)];
  for (const item of db.claimedRows) {
    db.events.set(item.event_id, { title: "Storytime", description: "Books" });
  }

  const originalNow = Date.now;
  let now = 1_000;
  Date.now = () => now;

  try {
    await withFetch(() => {
      now += 106_000;
      return Promise.resolve(new Response("ok"));
    }, async () => {
      const summary = await processTagQueueBatch(
        db as never,
        "http://local",
        "key",
      );

      assertEquals(summary.succeeded, 4);
    });
  } finally {
    Date.now = originalNow;
  }

  const release = db.rpcCalls.find((call) =>
    call.name === "release_unstarted_tag_queue_rows"
  );
  assertEquals(release?.args?.p_claimed_ids, [5]);
});
