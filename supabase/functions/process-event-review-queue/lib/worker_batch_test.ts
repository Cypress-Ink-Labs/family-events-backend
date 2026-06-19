import { assert, assertEquals } from "jsr:@std/assert"
import {
  type EventLlmReviewQueueRow,
  processReviewQueueBatch,
  type ReviewQueueDeps,
} from "./worker.ts"
import {
  type AppliedLlmEventReviewDecision,
  LLM_EVENT_REVIEW_DECISION,
  LLM_EVENT_REVIEW_STATUS,
  type LlmEventReviewDecision,
} from "../../event-review/types.ts"

// Characterization tests for the batch orchestration loop
// (`processReviewQueueBatch`): reap → claim → per-row process → summary, plus
// the wall-budget cut-off that releases unstarted rows. These pin the CURRENT
// transition + aggregation contract; they do not redefine policy. The per-row
// transitions themselves are covered separately in worker_test.ts; here we
// drive the loop with a fake queue store and assert how it aggregates the
// success / retry / dead-letter outcomes and how it handles the budget guard.

const REVIEWABLE_LLM_REVIEW_STATUS_PENDING = "pending"

interface FakeEvent {
  id: string
  status: "draft" | "published" | "rejected" | "archived"
  title: string
  description: string | null
  start_datetime: string
  end_datetime: string | null
  timezone: string
  venue_name: string | null
  address: string | null
  source_name: string | null
  source_url: string | null
  llm_review_status: string
  llm_review_decision: string | null
  updated_at: string
}

type QueueRow = EventLlmReviewQueueRow & {
  finished_at?: string | null
  started_at?: string | null
  last_error?: string | null
  updated_at?: string
}

class FakeSupabase {
  reaped = 0
  // Rows handed back from claim_event_llm_review_queue_batch, in claim order.
  claimable: QueueRow[] = []
  events = new Map<string, FakeEvent>()
  queue = new Map<number, QueueRow>()
  rpcCalls: Array<{ name: string; args?: Record<string, unknown> }> = []

  rpc(name: string, args?: Record<string, unknown>) {
    this.rpcCalls.push({ name, args })

    if (name === "reap_stuck_event_llm_review_rows") {
      return Promise.resolve({ data: this.reaped, error: null })
    }

    if (name === "claim_event_llm_review_queue_batch") {
      // Claim transitions the row to "processing"; record each in the store so
      // mark_event_llm_review_queue_row_started can advance it.
      for (const row of this.claimable) {
        this.queue.set(row.id, { ...row, status: "processing" })
      }
      return Promise.resolve({
        data: this.claimable.map((row) => ({ ...row, status: "processing" })),
        error: null,
      })
    }

    if (name === "mark_event_llm_review_queue_row_started") {
      const queueId = Number(args?.p_queue_id)
      const row = this.queue.get(queueId)
      if (!row || row.status !== "processing") {
        return Promise.resolve({ data: null, error: new Error("queue row missing") })
      }
      row.attempt_count += 1
      row.started_at = new Date().toISOString()
      this.queue.set(queueId, row)
      return Promise.resolve({ data: { ...row }, error: null })
    }

    if (name === "apply_event_llm_review_decision") {
      const queueId = Number(args?.p_queue_id)
      const eventId = String(args?.p_event_id)
      const event = this.events.get(eventId)
      const row = this.queue.get(queueId)
      if (!event || event.status !== "draft" || !row) {
        return Promise.resolve({ data: false, error: null })
      }
      const applied = args?.p_applied_decision as LlmEventReviewDecision
      Object.assign(event, {
        status:
          applied === LLM_EVENT_REVIEW_DECISION.APPROVE
            ? "published"
            : applied === LLM_EVENT_REVIEW_DECISION.REJECT
              ? "rejected"
              : "draft",
        llm_review_status: args?.p_review_status,
        llm_review_decision: applied,
        updated_at: new Date().toISOString(),
      })
      this.events.set(eventId, event)
      Object.assign(row, {
        status: "succeeded",
        finished_at: new Date().toISOString(),
        last_error: null,
        updated_at: new Date().toISOString(),
      })
      this.queue.set(queueId, row)
      return Promise.resolve({ data: true, error: null })
    }

    if (name === "release_unstarted_event_llm_review_rows") {
      // Mirror the real RPC (migration 20260601004000): claimed rows still
      // 'processing' with no started_at go back to 'pending', started_at NULL.
      const claimedIds = Array.isArray(args?.p_claimed_ids)
        ? (args.p_claimed_ids as Array<number | string>)
        : []
      for (const rawId of claimedIds) {
        const id = Number(rawId)
        const row = this.queue.get(id)
        if (!row) continue
        if (row.status === "processing" && (row.started_at === null || row.started_at === undefined)) {
          Object.assign(row, { status: "pending", started_at: null, updated_at: new Date().toISOString() })
          this.queue.set(id, row)
        }
      }
      return Promise.resolve({ data: null, error: null })
    }

    throw new Error(`Unhandled rpc in fake client: ${name}`)
  }

  from(table: string) {
    return new FakeQuery(this, table)
  }

  rpcNames() {
    return this.rpcCalls.map((call) => call.name)
  }
}

class FakeQuery {
  private operation: "select" | "update" | "insert" = "select"
  private payload: Record<string, unknown> | Record<string, unknown>[] | null = null
  private filters = new Map<string, unknown>()

  constructor(
    private readonly db: FakeSupabase,
    private readonly table: string
  ) {}

  select(_columns?: string) {
    if (this.operation !== "update") this.operation = "select"
    return this
  }

  update(payload: Record<string, unknown>) {
    this.operation = "update"
    this.payload = payload
    return this
  }

  insert(payload: Record<string, unknown> | Record<string, unknown>[]) {
    this.operation = "insert"
    this.payload = payload
    return this
  }

  eq(column: string, value: unknown) {
    this.filters.set(column, value)
    return this
  }

  maybeSingle() {
    return this.execute()
  }

  then<TResult1 = unknown, TResult2 = never>(
    onfulfilled?: ((value: unknown) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null
  ): Promise<TResult1 | TResult2> {
    return this.execute().then(onfulfilled, onrejected)
  }

  private execute() {
    // Feature-config lookups (memory + source-auto-reject) resolve to "no row"
    // so the batch stays on the plain reviewEvent path.
    if (this.operation === "select" && this.table === "ai_feature_config") {
      return Promise.resolve({ data: null, error: null })
    }

    if (this.operation === "select" && this.table === "events") {
      const id = this.filters.get("id")
      const event = id ? this.db.events.get(String(id)) : undefined
      return Promise.resolve({ data: event ?? null, error: null })
    }

    if (this.operation === "update" && this.table === "event_llm_review_queue") {
      const id = Number(this.filters.get("id"))
      const row = this.db.queue.get(id)
      if (row) {
        Object.assign(row, this.payload ?? {})
        this.db.queue.set(id, row)
      }
      return Promise.resolve({ data: null, error: null })
    }

    if (this.operation === "insert" && this.table === "event_llm_review_traces") {
      return Promise.resolve({ data: null, error: null })
    }

    return Promise.resolve({ data: null, error: null })
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
    llm_review_status: REVIEWABLE_LLM_REVIEW_STATUS_PENDING,
    llm_review_decision: null,
    updated_at: new Date().toISOString(),
    ...overrides,
  }
}

function buildQueueRow(overrides: Partial<QueueRow> = {}): QueueRow {
  return {
    id: 1,
    event_id: "event-1",
    source_id: null,
    source_run_id: "run-1",
    trigger_type: "import",
    status: "pending",
    attempt_count: 0,
    max_attempts: 3,
    next_attempt_at: new Date().toISOString(),
    ...overrides,
  }
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
  }
}

function decision(
  overrides: Partial<AppliedLlmEventReviewDecision> = {}
): AppliedLlmEventReviewDecision {
  return {
    status: LLM_EVENT_REVIEW_STATUS.SUCCEEDED,
    modelDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
    appliedDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
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
  }
}

// Seed the store with N reviewable rows (ids 1..N), each backed by a draft
// event. Returns the fake client ready for processReviewQueueBatch.
function seed(rows: Array<{ row?: Partial<QueueRow>; event?: Partial<FakeEvent> }>): FakeSupabase {
  const db = new FakeSupabase()
  rows.forEach((spec, index) => {
    const id = index + 1
    const eventId = `event-${id}`
    const event = buildEvent({ id: eventId, ...spec.event })
    const row = buildQueueRow({ id, event_id: eventId, ...spec.row })
    db.events.set(eventId, event)
    db.claimable.push(row)
  })
  return db
}

function depsFor(
  db: FakeSupabase,
  options: {
    reviewEvent?: ReviewQueueDeps["reviewEvent"]
    now?: () => number
    config?: Partial<ReturnType<typeof baseConfig>>
  } = {}
): ReviewQueueDeps {
  return {
    supabase: db as unknown as ReviewQueueDeps["supabase"],
    config: { ...baseConfig(), ...options.config },
    reviewEvent: options.reviewEvent,
    now: options.now,
  }
}

Deno.test("processReviewQueueBatch returns zeroed summary after an empty claim", async () => {
  const db = new FakeSupabase()
  db.reaped = 3

  const summary = await processReviewQueueBatch(depsFor(db))

  assertEquals(summary.claimed, 0)
  assertEquals(summary.reaped, 3)
  assertEquals(summary.succeeded, 0)
  assertEquals(summary.failed, 0)
  assertEquals(summary.dead, 0)
  assertEquals(db.rpcNames(), [
    "reap_stuck_event_llm_review_rows",
    "claim_event_llm_review_queue_batch",
  ])
})

Deno.test("processReviewQueueBatch happy path marks every claimed row succeeded", async () => {
  const db = seed([{}, {}, {}])

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      reviewEvent: async () =>
        decision({
          appliedDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
          modelDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
        }),
    })
  )

  assertEquals(summary.claimed, 3)
  assertEquals(summary.succeeded, 3)
  assertEquals(summary.approved, 3)
  assertEquals(summary.rejected, 0)
  assertEquals(summary.failed, 0)
  assertEquals(summary.retrying, 0)
  assertEquals(summary.dead, 0)
  for (const id of [1, 2, 3]) {
    assertEquals(db.queue.get(id)?.status, "succeeded")
  }
  // No row was released — the budget guard never fired.
  assert(!db.rpcNames().includes("release_unstarted_event_llm_review_rows"))
})

Deno.test("processReviewQueueBatch counts approve/reject/admin decisions independently", async () => {
  const db = seed([{}, {}, {}])
  const decisions = new Map<string, LlmEventReviewDecision>([
    ["event-1", LLM_EVENT_REVIEW_DECISION.APPROVE],
    ["event-2", LLM_EVENT_REVIEW_DECISION.REJECT],
    ["event-3", LLM_EVENT_REVIEW_DECISION.NEEDS_ADMIN_REVIEW],
  ])

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      reviewEvent: async (input) => {
        const applied = decisions.get(input.eventId) ?? LLM_EVENT_REVIEW_DECISION.APPROVE
        return decision({ appliedDecision: applied, modelDecision: applied })
      },
    })
  )

  assertEquals(summary.claimed, 3)
  assertEquals(summary.succeeded, 3)
  assertEquals(summary.approved, 1)
  assertEquals(summary.rejected, 1)
  assertEquals(summary.needsAdminReview, 1)
  assertEquals(summary.failed, 0)
  assertEquals(db.events.get("event-1")?.status, "published")
  assertEquals(db.events.get("event-2")?.status, "rejected")
  assertEquals(db.events.get("event-3")?.status, "draft")
})

Deno.test("processReviewQueueBatch schedules retry for a transient failure and keeps going", async () => {
  // Row 1 throws (retryable, under max_attempts) → retrying + failed;
  // rows 2 and 3 succeed. Aggregation must isolate the failure.
  const db = seed([{}, {}, {}])

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      reviewEvent: async (input) => {
        if (input.eventId === "event-1") throw new Error("network blip")
        return decision({
          appliedDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
          modelDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
        })
      },
    })
  )

  assertEquals(summary.claimed, 3)
  assertEquals(summary.succeeded, 2)
  assertEquals(summary.retrying, 1)
  // Current contract: a retrying row also increments `failed`.
  assertEquals(summary.failed, 1)
  assertEquals(summary.dead, 0)
  assertEquals(db.queue.get(1)?.status, "retrying")
  assert(typeof db.queue.get(1)?.next_attempt_at === "string")
  assertEquals(db.queue.get(2)?.status, "succeeded")
  assertEquals(db.queue.get(3)?.status, "succeeded")
})

Deno.test("processReviewQueueBatch dead-letters a row at max attempts", async () => {
  // Row claimed at attempt_count=2, max_attempts=3 → mark_started bumps it to 3,
  // so a throw exhausts attempts and dead-letters instead of retrying.
  const db = seed([{ row: { attempt_count: 2, max_attempts: 3 } }])

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      reviewEvent: async () => {
        throw new Error("still failing")
      },
    })
  )

  assertEquals(summary.claimed, 1)
  assertEquals(summary.dead, 1)
  assertEquals(summary.failed, 1)
  assertEquals(summary.retrying, 0)
  assertEquals(summary.succeeded, 0)
  assertEquals(db.queue.get(1)?.status, "dead")
})

Deno.test("processReviewQueueBatch dead-letters a missing event", async () => {
  // Claim a row whose event was deleted between enqueue and processing.
  const db = new FakeSupabase()
  db.claimable.push(buildQueueRow({ id: 1, event_id: "ghost" }))

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      reviewEvent: async () => decision(),
    })
  )

  assertEquals(summary.claimed, 1)
  assertEquals(summary.dead, 1)
  assertEquals(summary.failed, 1)
  assertEquals(db.queue.get(1)?.status, "dead")
  assert(String(db.queue.get(1)?.last_error).includes("event missing"))
})

Deno.test("processReviewQueueBatch aggregates a mixed batch (success + retry + dead)", async () => {
  // event-1 succeeds, event-2 transiently fails (retry), event-3 exhausts (dead).
  const db = seed([{}, {}, { row: { attempt_count: 2, max_attempts: 3 } }])

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      reviewEvent: async (input) => {
        if (input.eventId === "event-2") throw new Error("transient")
        if (input.eventId === "event-3") throw new Error("exhausted")
        return decision({
          appliedDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
          modelDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
        })
      },
    })
  )

  assertEquals(summary.claimed, 3)
  assertEquals(summary.succeeded, 1)
  assertEquals(summary.approved, 1)
  assertEquals(summary.retrying, 1)
  assertEquals(summary.dead, 1)
  // failed = retrying (1) + dead (1).
  assertEquals(summary.failed, 2)
  assertEquals(db.queue.get(1)?.status, "succeeded")
  assertEquals(db.queue.get(2)?.status, "retrying")
  assertEquals(db.queue.get(3)?.status, "dead")
})

Deno.test("processReviewQueueBatch releases unstarted rows once the wall budget is spent", async () => {
  // Three rows claimed. A fake clock jumps past the 110s budget after the first
  // row, so rows 2 and 3 are never started and must be released back.
  const db = seed([{}, {}, {}])

  let calls = 0
  // now() is read once at batch start, then once before each row.
  // Sequence: start=0, before row1=0 (under budget), before row2=200_000 (over).
  const clock = [0, 0, 200_000, 200_000, 200_000]
  const now = () => {
    const value = clock[Math.min(calls, clock.length - 1)] ?? 200_000
    calls += 1
    return value
  }

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      now,
      reviewEvent: async () =>
        decision({
          appliedDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
          modelDecision: LLM_EVENT_REVIEW_DECISION.APPROVE,
        }),
    })
  )

  assertEquals(summary.claimed, 3)
  // Only the first row ran before the budget cut-off.
  assertEquals(summary.succeeded, 1)
  assertEquals(summary.failed, 0)

  const release = db.rpcCalls.find(
    (call) => call.name === "release_unstarted_event_llm_review_rows"
  )
  assert(release !== undefined, "expected unstarted rows to be released")
  assertEquals(release?.args?.p_claimed_ids, [2, 3])
  // Released rows are returned to 'pending' with started_at cleared (real RPC contract).
  assertEquals(db.queue.get(2)?.status, "pending")
  assertEquals(db.queue.get(3)?.status, "pending")
  assertEquals(db.queue.get(2)?.started_at, null)
  assertEquals(db.queue.get(3)?.started_at, null)
})

Deno.test("processReviewQueueBatch releases the whole batch when the budget is spent before row one", async () => {
  const db = seed([{}, {}])

  let calls = 0
  // start=0, then before row1 the clock is already over budget.
  const clock = [0, 200_000, 200_000]
  const now = () => {
    const value = clock[Math.min(calls, clock.length - 1)] ?? 200_000
    calls += 1
    return value
  }

  const summary = await processReviewQueueBatch(
    depsFor(db, {
      now,
      reviewEvent: async () => decision(),
    })
  )

  assertEquals(summary.claimed, 2)
  assertEquals(summary.succeeded, 0)
  const release = db.rpcCalls.find(
    (call) => call.name === "release_unstarted_event_llm_review_rows"
  )
  assertEquals(release?.args?.p_claimed_ids, [1, 2])
})
