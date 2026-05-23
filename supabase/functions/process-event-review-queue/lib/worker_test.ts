import { assert, assertEquals } from "jsr:@std/assert";
import {
  type EventLlmReviewQueueRow,
  processReviewQueueRow,
  type ReviewQueueDeps,
} from "./worker.ts";
import type { AppliedLlmEventReviewDecision } from "../../event-review/types.ts";

interface FakeEvent {
  id: string;
  status: "draft" | "published" | "rejected" | "archived";
  title: string;
  description: string | null;
  start_datetime: string;
  end_datetime: string | null;
  timezone: string;
  venue_name: string | null;
  address: string | null;
  source_name: string | null;
  source_url: string | null;
  llm_review_status: string;
  llm_review_decision: string | null;
  llm_review_confidence: number | null;
  llm_review_reason: string | null;
  llm_review_flags: string[];
  llm_review_provider: string | null;
  llm_review_model: string | null;
  llm_review_prompt_version: string | null;
  llm_reviewed_at: string | null;
  llm_review_error: string | null;
  updated_at: string;
}

type QueueRow = EventLlmReviewQueueRow & {
  finished_at?: string | null;
  started_at?: string | null;
  last_error?: string | null;
  updated_at?: string;
};

class FakeSupabase {
  events = new Map<string, FakeEvent>();
  queue = new Map<number, QueueRow>();
  traces: Record<string, unknown>[] = [];
  tagQueue: Record<string, unknown>[] = [];

  rpc(name: string, args: Record<string, unknown>) {
    if (name === "mark_event_llm_review_queue_row_started") {
      const queueId = Number(args.p_queue_id);
      const row = this.queue.get(queueId);
      if (!row || row.status !== "processing") {
        return Promise.resolve({
          data: null,
          error: new Error("queue row missing"),
        });
      }
      row.attempt_count += 1;
      row.started_at = new Date().toISOString();
      this.queue.set(queueId, row);
      return Promise.resolve({ data: { ...row }, error: null });
    }

    if (name === "apply_event_llm_review_decision") {
      const queueId = Number(args.p_queue_id);
      const eventId = String(args.p_event_id);
      const event = this.events.get(eventId);
      const row = this.queue.get(queueId);
      if (!event || event.status !== "draft" || !row) {
        return Promise.resolve({ data: false, error: null });
      }

      const appliedDecision = args.p_applied_decision as
        | "approve"
        | "reject"
        | "needs_admin_review";
      Object.assign(event, {
        status: appliedDecision === "approve"
          ? "published"
          : appliedDecision === "reject"
          ? "rejected"
          : "draft",
        llm_review_status: args.p_review_status,
        llm_review_decision: appliedDecision,
        llm_review_confidence: args.p_confidence,
        llm_review_reason: args.p_reason,
        llm_review_flags: args.p_flags,
        llm_review_provider: args.p_provider,
        llm_review_model: args.p_model,
        llm_review_prompt_version: args.p_prompt_version,
        llm_reviewed_at: new Date().toISOString(),
        llm_review_error: args.p_error_message,
        updated_at: new Date().toISOString(),
      });
      this.events.set(eventId, event);
      this.traces.push({
        event_id: eventId,
        queue_id: queueId,
        source_id: args.p_source_id,
        source_run_id: args.p_source_run_id,
        provider: args.p_provider,
        model: args.p_model,
        prompt_version: args.p_prompt_version,
        status: args.p_review_status,
        model_decision: args.p_model_decision,
        applied_decision: appliedDecision,
        confidence: args.p_confidence,
        reason: args.p_reason,
        flags: args.p_flags,
        suggested_category: args.p_suggested_category,
        normalized_title: args.p_normalized_title,
        raw_response: args.p_raw_response,
        error_code: args.p_error_code,
        error_message: args.p_error_message,
        input_snapshot: args.p_input_snapshot,
        processing_ms: args.p_processing_ms,
      });

      if (appliedDecision !== "reject") {
        const duplicate = this.tagQueue.some(
          (existing) =>
            String((existing as { event_id?: string }).event_id ?? "") ===
              eventId,
        );
        if (!duplicate) {
          this.tagQueue.push({
            event_id: eventId,
            source_run_id: args.p_source_run_id,
            trigger_type: "import",
          });
        }
      }

      Object.assign(row, {
        status: "succeeded",
        finished_at: new Date().toISOString(),
        last_error: null,
        updated_at: new Date().toISOString(),
      });
      this.queue.set(queueId, row);
      return Promise.resolve({ data: true, error: null });
    }

    throw new Error(`Unhandled rpc in fake client: ${name}`);
  }

  from(table: string) {
    return new FakeQuery(this, table);
  }
}

class FakeQuery {
  private operation: "select" | "update" | "insert" = "select";
  private payload: Record<string, unknown> | Record<string, unknown>[] | null =
    null;
  private filters = new Map<string, unknown>();
  private wantsSingle = false;

  constructor(
    private readonly db: FakeSupabase,
    private readonly table: string,
  ) {}

  select(_columns?: string) {
    if (this.operation !== "update") {
      this.operation = "select";
    }
    this.wantsSingle = true;
    return this;
  }

  update(payload: Record<string, unknown>) {
    this.operation = "update";
    this.payload = payload;
    return this;
  }

  insert(payload: Record<string, unknown> | Record<string, unknown>[]) {
    this.operation = "insert";
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

  private execute(expectSingle: boolean) {
    if (this.operation === "select" && this.table === "events") {
      const id = this.filters.get("id");
      const event = id ? this.db.events.get(String(id)) : undefined;
      return Promise.resolve({ data: event ?? null, error: null });
    }

    if (this.operation === "update" && this.table === "events") {
      const id = String(this.filters.get("id"));
      const statusFilter = this.filters.get("status");
      const event = this.db.events.get(id) ?? null;
      if (!event) {
        return Promise.resolve({ data: null, error: null });
      }
      if (statusFilter && event.status !== statusFilter) {
        return Promise.resolve({ data: null, error: null });
      }
      Object.assign(event, this.payload ?? {});
      this.db.events.set(id, event);
      if (expectSingle || this.wantsSingle) {
        return Promise.resolve({ data: { id }, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    }

    if (
      this.operation === "update" && this.table === "event_llm_review_queue"
    ) {
      const id = Number(this.filters.get("id"));
      const row = this.db.queue.get(id);
      if (!row) return Promise.resolve({ data: null, error: null });
      Object.assign(row, this.payload ?? {});
      this.db.queue.set(id, row);
      return Promise.resolve({ data: null, error: null });
    }

    if (
      this.operation === "insert" && this.table === "event_llm_review_traces"
    ) {
      if (Array.isArray(this.payload)) {
        this.db.traces.push(...this.payload);
      } else if (this.payload) {
        this.db.traces.push(this.payload);
      }
      return Promise.resolve({ data: null, error: null });
    }

    if (this.operation === "insert" && this.table === "event_tag_queue") {
      const rows = Array.isArray(this.payload) ? this.payload : [this.payload];
      for (const row of rows) {
        if (!row) continue;
        const eventId = String((row as { event_id?: string }).event_id ?? "");
        const duplicate = this.db.tagQueue.some(
          (existing) =>
            String((existing as { event_id?: string }).event_id ?? "") ===
              eventId,
        );
        if (duplicate) {
          return Promise.resolve({ data: null, error: { code: "23505" } });
        }
        this.db.tagQueue.push(row);
      }
      return Promise.resolve({ data: null, error: null });
    }

    return Promise.resolve({ data: null, error: null });
  }
}

function buildEvent(overrides: Partial<FakeEvent> = {}): FakeEvent {
  return {
    id: "event-1",
    status: "draft",
    title: "Family Story Time",
    description: "Join us for books and songs",
    start_datetime: "2026-06-01T14:00:00Z",
    end_datetime: null,
    timezone: "America/Chicago",
    venue_name: "Main Library",
    address: "10 Main St",
    source_name: "Library Feed",
    source_url: "https://example.com/event/1",
    llm_review_status: "pending",
    llm_review_decision: null,
    llm_review_confidence: null,
    llm_review_reason: null,
    llm_review_flags: [],
    llm_review_provider: null,
    llm_review_model: null,
    llm_review_prompt_version: null,
    llm_reviewed_at: null,
    llm_review_error: null,
    updated_at: new Date().toISOString(),
    ...overrides,
  };
}

function buildQueueRow(overrides: Partial<QueueRow> = {}): QueueRow {
  return {
    id: 1,
    event_id: "event-1",
    source_id: null,
    source_run_id: "run-1",
    trigger_type: "import",
    status: "processing",
    attempt_count: 0,
    max_attempts: 3,
    next_attempt_at: new Date().toISOString(),
    ...overrides,
  };
}

function baseConfig() {
  return {
    enabled: true,
    provider: "openai-compatible",
    baseUrl: "https://example.com/v1",
    model: "model-x",
    apiKey: "key",
    promptVersion: "event-review-v1",
    confidenceThreshold: 0.75,
    timeoutMs: 30_000,
    maxAttempts: 3,
    retryBaseMs: 60_000,
    persistRawResponse: false,
    valid: true,
    invalidReason: null,
  };
}

function decision(
  overrides: Partial<AppliedLlmEventReviewDecision> = {},
): AppliedLlmEventReviewDecision {
  return {
    status: "succeeded",
    modelDecision: "approve",
    appliedDecision: "approve",
    confidence: 0.91,
    reason: "Clear family event",
    flags: [],
    suggestedCategory: null,
    normalizedTitle: null,
    provider: "openai-compatible",
    model: "model-x",
    promptVersion: "event-review-v1",
    rawResponse: null,
    errorCode: null,
    errorMessage: null,
    processingMs: 30,
    ...overrides,
  };
}

async function runRowTest(options: {
  event?: Partial<FakeEvent>;
  row?: Partial<QueueRow>;
  reviewEvent?: ReviewQueueDeps["reviewEvent"];
}) {
  const supabase = new FakeSupabase();
  const event = buildEvent(options.event);
  const row = buildQueueRow(options.row);
  supabase.events.set(event.id, event);
  supabase.queue.set(row.id, row);

  const deps: ReviewQueueDeps = {
    supabase: supabase as unknown as ReviewQueueDeps["supabase"],
    config: baseConfig(),
    reviewEvent: options.reviewEvent,
  };

  const result = await processReviewQueueRow(deps, row);
  return { supabase, eventId: event.id, queueId: row.id, result };
}

Deno.test("approve publishes event and enqueues tag queue", async () => {
  const { supabase, eventId, result } = await runRowTest({
    reviewEvent: async () =>
      decision({ appliedDecision: "approve", modelDecision: "approve" }),
  });

  assertEquals(result.outcome, "succeeded");
  assertEquals(supabase.events.get(eventId)?.status, "published");
  assertEquals(supabase.tagQueue.length, 1);
  assertEquals(
    supabase.queue.get(1)?.status,
    "succeeded",
  );
});

Deno.test("reject rejects event and does not enqueue tag queue", async () => {
  const { supabase, eventId } = await runRowTest({
    reviewEvent: async () =>
      decision({ appliedDecision: "reject", modelDecision: "reject" }),
  });

  assertEquals(supabase.events.get(eventId)?.status, "rejected");
  assertEquals(supabase.tagQueue.length, 0);
});

Deno.test("needs_admin_review keeps draft and enqueues tag queue", async () => {
  const { supabase, eventId } = await runRowTest({
    reviewEvent: async () =>
      decision({
        appliedDecision: "needs_admin_review",
        modelDecision: "approve",
        confidence: 0.62,
      }),
  });

  assertEquals(supabase.events.get(eventId)?.status, "draft");
  assertEquals(supabase.tagQueue.length, 1);
});

Deno.test("provider timeout routes to admin review", async () => {
  const { supabase, eventId, result } = await runRowTest({
    reviewEvent: async () =>
      decision({
        status: "failed",
        appliedDecision: "needs_admin_review",
        modelDecision: null,
        errorCode: "provider_timeout",
        errorMessage: "timed out",
      }),
  });

  assertEquals(result.outcome, "succeeded");
  assertEquals(result.failed, true);
  assertEquals(supabase.events.get(eventId)?.status, "draft");
  assertEquals(supabase.events.get(eventId)?.llm_review_status, "failed");
});

Deno.test("malformed provider output routes to admin review", async () => {
  const { supabase, eventId } = await runRowTest({
    reviewEvent: async () =>
      decision({
        status: "failed",
        appliedDecision: "needs_admin_review",
        modelDecision: null,
        errorCode: "malformed_json",
      }),
  });

  assertEquals(supabase.events.get(eventId)?.status, "draft");
  assertEquals(
    supabase.events.get(eventId)?.llm_review_decision,
    "needs_admin_review",
  );
});

Deno.test("disabled feature flag routes to admin review", async () => {
  const supabase = new FakeSupabase();
  const event = buildEvent();
  const row = buildQueueRow();
  supabase.events.set(event.id, event);
  supabase.queue.set(row.id, row);

  const result = await processReviewQueueRow(
    {
      supabase: supabase as unknown as ReviewQueueDeps["supabase"],
      config: {
        ...baseConfig(),
        enabled: false,
      },
    },
    row,
  );

  assertEquals(result.outcome, "succeeded");
  assertEquals(supabase.events.get(event.id)?.status, "draft");
  assertEquals(supabase.events.get(event.id)?.llm_review_status, "failed");
});

Deno.test("low confidence routes to admin review", async () => {
  const { supabase, eventId } = await runRowTest({
    reviewEvent: async () =>
      decision({
        status: "succeeded",
        appliedDecision: "needs_admin_review",
        modelDecision: "approve",
        confidence: 0.5,
      }),
  });

  assertEquals(supabase.events.get(eventId)?.status, "draft");
  assertEquals(supabase.events.get(eventId)?.llm_review_status, "succeeded");
  assertEquals(
    supabase.events.get(eventId)?.llm_review_decision,
    "needs_admin_review",
  );
});

Deno.test("retryable failures increment attempts and schedule retry", async () => {
  const { supabase, result } = await runRowTest({
    reviewEvent: async () => {
      throw new Error("network error");
    },
  });

  assertEquals(result.outcome, "retrying");
  const row = supabase.queue.get(1);
  assertEquals(row?.status, "retrying");
  assert(row?.attempt_count === 1);
  assert(row?.next_attempt_at !== undefined);
});

Deno.test("exhausted attempts mark queue row dead", async () => {
  const { supabase, result } = await runRowTest({
    row: {
      attempt_count: 2,
      max_attempts: 3,
    },
    reviewEvent: async () => {
      throw new Error("still failing");
    },
  });

  assertEquals(result.outcome, "dead");
  assertEquals(supabase.queue.get(1)?.status, "dead");
});

Deno.test("already processed event is skipped", async () => {
  const { supabase, result } = await runRowTest({
    event: {
      status: "published",
      llm_review_status: "succeeded",
    },
    reviewEvent: async () => decision(),
  });

  assertEquals(result.outcome, "skipped");
  assertEquals(supabase.tagQueue.length, 0);
  assertEquals(supabase.queue.get(1)?.status, "succeeded");
});

Deno.test("duplicate queue rows do not cause duplicate state transitions", async () => {
  const supabase = new FakeSupabase();
  const event = buildEvent();
  const row1 = buildQueueRow({ id: 1, event_id: event.id });
  const row2 = buildQueueRow({ id: 2, event_id: event.id });

  supabase.events.set(event.id, event);
  supabase.queue.set(row1.id, row1);
  supabase.queue.set(row2.id, row2);

  const deps: ReviewQueueDeps = {
    supabase: supabase as unknown as ReviewQueueDeps["supabase"],
    config: baseConfig(),
    reviewEvent: async () =>
      decision({ appliedDecision: "approve", modelDecision: "approve" }),
  };

  const first = await processReviewQueueRow(deps, row1);
  const second = await processReviewQueueRow(deps, row2);

  assertEquals(first.outcome, "succeeded");
  assertEquals(second.outcome, "skipped");
  assertEquals(supabase.events.get(event.id)?.status, "published");
  assertEquals(supabase.tagQueue.length, 1);
});
