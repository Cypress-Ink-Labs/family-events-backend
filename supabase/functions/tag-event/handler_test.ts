import { assert, assertEquals } from "jsr:@std/assert";
import { createTagEventHandler, resolveClassification } from "./handler.ts";

type FakeTag = { id: string; slug: string; name: string };
type FakeEvent = {
  id: string;
  title: string;
  description: string | null;
  price: number | null;
  is_free: boolean;
  venue_name: string | null;
  address: string | null;
  latitude: number | null;
  longitude: number | null;
  city_id: string | null;
  age_min?: number | null;
  age_max?: number | null;
  ai_confidence?: number | null;
  ai_tag_provider?: string | null;
  ai_tag_model?: string | null;
  ai_tag_status?: string | null;
};
type FakeEventTag = {
  event_id: string;
  tag_id: string;
  confidence: number;
  is_manual_override: boolean;
};
type FakeCity = {
  id: string;
  name: string;
  state: string | null;
  latitude: number | null;
  longitude: number | null;
};

class FakeSupabase {
  events = new Map<string, FakeEvent>();
  tags: FakeTag[] = [];
  eventTags: FakeEventTag[] = [];
  traces: Record<string, unknown>[] = [];
  cities = new Map<string, FakeCity>();
  aiFeatureConfig: {
    feature: string;
    model_id: string;
    enabled: boolean;
    approved_ai_models: { provider: string } | null;
  } | null = null;

  from(table: string) {
    return new FakeQuery(this, table);
  }
}

class FakeQuery {
  private operation: "select" | "insert" | "delete" | "update" | "upsert" =
    "select";
  private filters = new Map<string, unknown>();
  private payload: unknown = null;

  constructor(
    private readonly db: FakeSupabase,
    private readonly table: string,
  ) {}

  select(_columns?: string) {
    this.operation = "select";
    return this;
  }

  insert(payload: unknown) {
    this.operation = "insert";
    this.payload = payload;
    return this;
  }

  delete() {
    this.operation = "delete";
    return this;
  }

  update(payload: unknown) {
    this.operation = "update";
    this.payload = payload;
    return this;
  }

  upsert(payload: unknown, _options?: unknown) {
    this.operation = "upsert";
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
      const event = this.db.events.get(String(this.filters.get("id"))) ?? null;
      return Promise.resolve({ data: event, error: null });
    }

    if (this.operation === "select" && this.table === "tags") {
      return Promise.resolve({ data: this.db.tags, error: null });
    }

    if (this.operation === "select" && this.table === "event_tags") {
      const eventId = String(this.filters.get("event_id"));
      const manual = this.filters.get("is_manual_override");
      return Promise.resolve({
        data: this.db.eventTags
          .filter((row) => row.event_id === eventId)
          .filter((row) =>
            typeof manual === "boolean"
              ? row.is_manual_override === manual
              : true
          )
          .map((row) => ({ tag_id: row.tag_id })),
        error: null,
      });
    }

    if (this.operation === "select" && this.table === "cities") {
      const city = this.db.cities.get(String(this.filters.get("id"))) ?? null;
      return Promise.resolve({ data: city, error: null });
    }

    if (this.operation === "insert" && this.table === "event_ai_traces") {
      this.db.traces.push(this.payload as Record<string, unknown>);
      return Promise.resolve({ data: null, error: null });
    }

    if (this.operation === "delete" && this.table === "event_tags") {
      const eventId = String(this.filters.get("event_id"));
      const manual = this.filters.get("is_manual_override");
      this.db.eventTags = this.db.eventTags.filter((row) => {
        if (row.event_id !== eventId) return true;
        if (typeof manual === "boolean") {
          return row.is_manual_override !== manual;
        }
        return false;
      });
      return Promise.resolve({ data: null, error: null });
    }

    if (this.operation === "upsert" && this.table === "event_tags") {
      const rows = this.payload as FakeEventTag[];
      for (const row of rows) {
        const existingIndex = this.db.eventTags.findIndex((existing) =>
          existing.event_id === row.event_id && existing.tag_id === row.tag_id
        );
        if (existingIndex >= 0) {
          this.db.eventTags[existingIndex] = row;
        } else {
          this.db.eventTags.push(row);
        }
      }
      return Promise.resolve({ data: null, error: null });
    }

    if (this.operation === "update" && this.table === "events") {
      const id = String(this.filters.get("id"));
      const event = this.db.events.get(id);
      if (event) {
        Object.assign(event, this.payload);
        this.db.events.set(id, event);
      }
      return Promise.resolve({
        data: expectSingle ? event ?? null : null,
        error: null,
      });
    }

    if (this.operation === "select" && this.table === "ai_feature_config") {
      const feature = this.filters.get("feature");
      if (this.db.aiFeatureConfig?.feature === feature) {
        return Promise.resolve({ data: this.db.aiFeatureConfig, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    }

    throw new Error(`Unhandled fake query: ${this.operation} ${this.table}`);
  }
}

function makeRequest(body: unknown): Request {
  return new Request("http://localhost/tag-event", {
    method: "POST",
    headers: {
      Authorization: "Bearer service",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

async function readJson(response: Response) {
  return await response.json() as Record<string, unknown>;
}

function authOk() {
  return { ok: true, source: "service_role", userId: null } as const;
}

Deno.test("handleTagEvent rejects invalid service-role calls", async () => {
  const handler = createTagEventHandler({
    requireServiceRole: () => ({
      ok: false,
      status: 403,
      message: "service role required",
    }),
  });

  const response = await handler(makeRequest({ title: "Storytime" }));

  assertEquals(response.status, 403);
  assertEquals(await readJson(response), { error: "service role required" });
});

Deno.test("handleTagEvent rejects requests without a title", async () => {
  const db = new FakeSupabase();
  const handler = createTagEventHandler({
    createSupabaseClient: () => db as never,
    requireServiceRole: authOk,
    loadFeatureConfig: () => Promise.resolve(null),
  });

  const response = await handler(makeRequest({}));

  assertEquals(response.status, 400);
  assertEquals(await readJson(response), { error: "title is required" });
  assertEquals(db.traces.length, 0);
});

Deno.test("resolveClassification falls back to keyword tags without provider credentials", async () => {
  const previous = {
    AI_PROVIDER: Deno.env.get("AI_PROVIDER"),
    AI_BASE_URL: Deno.env.get("AI_BASE_URL"),
    AI_API_KEY: Deno.env.get("AI_API_KEY"),
    OPENAI_API_KEY: Deno.env.get("OPENAI_API_KEY"),
    OPENAI_MODEL: Deno.env.get("OPENAI_MODEL"),
  };
  for (const key of Object.keys(previous)) {
    Deno.env.delete(key);
  }

  try {
    const result = await resolveClassification({
      eventId: null,
      sourceRunId: null,
      triggerType: "import",
      traceStartedAt: Date.now(),
      title: "Free outdoor storytime for ages 2 to 5 years",
      description: "Meet at the park for a no cost library reading.",
      currentEvent: null,
    }, [
      { id: "tag-storytime", slug: "storytime", name: "Storytime" },
      { id: "tag-outdoor", slug: "outdoor", name: "Outdoor" },
      { id: "tag-free", slug: "free", name: "Free" },
    ]);

    assertEquals(result.llmUsage, null);
    assertEquals(result.classification.status, "fallback");
    assertEquals(
      result.classification.fallbackReason,
      "AI provider is not configured",
    );
    assertEquals(result.classification.ageMin, 2);
    assertEquals(result.classification.ageMax, 5);
    assertEquals(result.classification.isFree, true);
    assert(result.classification.tags.some((tag) => tag.slug === "storytime"));
    assert(result.classification.tags.some((tag) => tag.slug === "outdoor"));
    assert(result.classification.tags.some((tag) => tag.slug === "free"));
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
  }
});

Deno.test("handleTagEvent preserves manual tags and only fills missing event fields", async () => {
  const db = new FakeSupabase();
  db.tags = [
    { id: "tag-free", slug: "free", name: "Free" },
    { id: "tag-outdoor", slug: "outdoor", name: "Outdoor" },
    { id: "tag-manual", slug: "manual", name: "Manual" },
  ];
  db.events.set("evt-1", {
    id: "evt-1",
    title: "Existing park meetup",
    description: "Old description",
    price: 9,
    is_free: false,
    venue_name: "Existing Venue",
    address: null,
    latitude: null,
    longitude: null,
    city_id: "city-1",
  });
  db.eventTags = [
    {
      event_id: "evt-1",
      tag_id: "tag-manual",
      confidence: 1,
      is_manual_override: true,
    },
    {
      event_id: "evt-1",
      tag_id: "tag-old",
      confidence: 0.25,
      is_manual_override: false,
    },
  ];
  db.cities.set("city-1", {
    id: "city-1",
    name: "Baton Rouge",
    state: "LA",
    latitude: 30.4515,
    longitude: -91.1871,
  });

  const geocodeQueries: string[] = [];
  const handler = createTagEventHandler({
    createSupabaseClient: () => db as never,
    requireServiceRole: authOk,
    classify: async () => ({
      classification: {
        tags: [
          { slug: "outdoor", confidence: 0.9, reason: "park" },
          { slug: "free", confidence: 0.8, reason: "free" },
        ],
        ageMin: 3,
        ageMax: 8,
        price: 12,
        isFree: true,
        venueName: "New Venue",
        provider: "openai",
        reasoningSummary: "classified",
        status: "success",
        fallbackReason: null,
        model: "gpt-4o-mini",
      },
      llmUsage: {
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
        llmLatencyMs: 25,
        finishReason: "stop",
      },
    }),
    geocode: (query) => {
      geocodeQueries.push(query);
      return Promise.resolve(null);
    },
    loadFeatureConfig: () => Promise.resolve(null),
  });

  const response = await handler(makeRequest({
    event_id: "evt-1",
    title: "Fresh park meetup",
    source_run_id: "run-1",
    trigger_type: "reclassify",
  }));

  assertEquals(response.status, 200);
  const body = await readJson(response);
  assertEquals(body.status, "success");
  assertEquals(body.overall_confidence, 0.8500000000000001);

  const updatedEvent = db.events.get("evt-1");
  assertEquals(updatedEvent?.price, 9);
  assertEquals(updatedEvent?.is_free, true);
  assertEquals(updatedEvent?.venue_name, "Existing Venue");
  assertEquals(updatedEvent?.age_min, 3);
  assertEquals(updatedEvent?.age_max, 8);
  assertEquals(updatedEvent?.latitude, 30.4515);
  assertEquals(updatedEvent?.longitude, -91.1871);
  assertEquals(updatedEvent?.ai_tag_status, "success");
  assert(geocodeQueries[0].includes("Existing Venue"));

  assertEquals(db.traces.length, 1);
  assertEquals(db.traces[0].event_id, "evt-1");
  assertEquals(db.traces[0].source_run_id, "run-1");
  assertEquals(db.traces[0].status, "success");
  assertEquals(db.traces[0].predicted_fields, {
    age_min: 3,
    age_max: 8,
    price: 12,
    is_free: true,
    venue_name: "New Venue",
  });

  assertEquals(
    db.eventTags
      .map((row) => `${row.tag_id}:${row.is_manual_override}`)
      .sort(),
    ["tag-free:false", "tag-manual:true", "tag-outdoor:false"],
  );
});

Deno.test("handleTagEvent returns fallback output from classification failures", async () => {
  const db = new FakeSupabase();
  db.tags = [{ id: "tag-storytime", slug: "storytime", name: "Storytime" }];
  const handler = createTagEventHandler({
    createSupabaseClient: () => db as never,
    requireServiceRole: authOk,
    classify: async () => ({
      classification: {
        tags: [{ slug: "storytime", confidence: 0.7, reason: "keyword" }],
        ageMin: null,
        ageMax: null,
        price: null,
        isFree: false,
        venueName: null,
        provider: "openai",
        reasoningSummary: "Keyword fallback classified this event.",
        status: "fallback",
        fallbackReason: "openai classification failed (500)",
        model: "gpt-4o-mini",
      },
      llmUsage: null,
    }),
    loadFeatureConfig: () => Promise.resolve(null),
  });

  const response = await handler(makeRequest({
    title: "Library storytime",
    description: "Stories and songs.",
  }));

  assertEquals(response.status, 200);
  const body = await readJson(response);
  assertEquals(body.status, "fallback");
  assertEquals(body.fallback_reason, "openai classification failed (500)");
  assertEquals(body.processed, true);
  assertEquals(db.traces.length, 0);
});

Deno.test("handleTagEvent includes prompt_version in trace insert", async () => {
  const db = new FakeSupabase();
  db.tags = [{ id: "tag-outdoor", slug: "outdoor", name: "Outdoor" }];
  db.events.set("evt-pv", {
    id: "evt-pv",
    title: "Park day",
    description: "Outdoor fun",
    price: null,
    is_free: true,
    venue_name: null,
    address: null,
    latitude: 30,
    longitude: -90,
    city_id: null,
  });

  const handler = createTagEventHandler({
    createSupabaseClient: () => db as never,
    requireServiceRole: authOk,
    classify: async () => ({
      classification: {
        tags: [{ slug: "outdoor", confidence: 0.9, reason: "park" }],
        ageMin: null,
        ageMax: null,
        price: null,
        isFree: true,
        venueName: null,
        provider: "openai" as const,
        reasoningSummary: null,
        status: "success" as const,
        fallbackReason: null,
        model: "gpt-4.1-nano",
      },
      llmUsage: null,
    }),
    geocode: () => Promise.resolve(null),
    loadFeatureConfig: () => Promise.resolve(null),
  });

  await handler(makeRequest({ event_id: "evt-pv", title: "Park day" }));

  assertEquals(db.traces.length, 1);
  assertEquals(typeof db.traces[0].prompt_version, "string");
  assert((db.traces[0].prompt_version as string).length > 0);
});

Deno.test("resolveClassification uses model from DB config when provided", async () => {
  const previous = {
    AI_PROVIDER: Deno.env.get("AI_PROVIDER"),
    AI_MODEL: Deno.env.get("AI_MODEL"),
    AI_BASE_URL: Deno.env.get("AI_BASE_URL"),
    AI_API_KEY: Deno.env.get("AI_API_KEY"),
  };
  for (const key of Object.keys(previous)) Deno.env.delete(key);

  try {
    const result = await resolveClassification(
      {
        eventId: null,
        sourceRunId: null,
        triggerType: "import",
        traceStartedAt: Date.now(),
        title: "Story time at the park",
        description: "Free outdoor reading for kids.",
        currentEvent: null,
      },
      [{ id: "tag-outdoor", slug: "outdoor", name: "Outdoor" }],
      { modelId: "gpt-4.1-nano", provider: "openai", enabled: true },
    );

    // No API key configured so falls back to keyword classification,
    // but the model name from DB config flows through to the result.
    assertEquals(result.classification.model, "gpt-4.1-nano");
    assertEquals(result.classification.status, "fallback");
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
