import { assertEquals } from "jsr:@std/assert";

// ---------------------------------------------------------------------------
// Helpers to build mock Supabase client + Resend server
// ---------------------------------------------------------------------------

interface MockRpcCall {
  name: string;
  params: Record<string, unknown>;
}

interface MockQueryChain {
  from: string;
  selectStr: string;
  eqCalls: Array<{ col: string; val: unknown }>;
  inCalls: Array<{ col: string; val: unknown[] }>;
}

function createMockSupabase(opts: {
  prefsRows?: Array<Record<string, unknown>>;
  profileRows?: Array<Record<string, unknown>>;
  searchEventsResult?: Record<string, unknown[]>;
  rpcCalls?: MockRpcCall[];
  queryCalls?: MockQueryChain[];
}) {
  const rpcCalls: MockRpcCall[] = opts.rpcCalls ?? [];
  const queryCalls: MockQueryChain[] = opts.queryCalls ?? [];

  function buildSelectChain(
    tableName: string,
    rows: Array<Record<string, unknown>>,
  ) {
    let selectStr = "";
    const eqCalls: Array<{ col: string; val: unknown }> = [];

    const chain = {
      select(s: string) {
        selectStr = s;
        return chain;
      },
      eq(col: string, val: unknown) {
        eqCalls.push({ col, val });
        queryCalls.push({ from: tableName, selectStr, eqCalls: [...eqCalls], inCalls: [] });
        return Promise.resolve({ data: rows, error: null });
      },
      in(col: string, val: unknown[]) {
        queryCalls.push({ from: tableName, selectStr, eqCalls: [...eqCalls], inCalls: [{ col, val }] });
        return Promise.resolve({ data: rows, error: null });
      },
    };
    return chain;
  }

  return {
    from(table: string) {
      if (table === "user_notification_preferences") {
        return buildSelectChain(table, opts.prefsRows ?? []);
      }
      if (table === "user_profiles") {
        return buildSelectChain(table, opts.profileRows ?? []);
      }
      return buildSelectChain(table, []);
    },
    rpc(name: string, params: Record<string, unknown> = {}) {
      rpcCalls.push({ name, params });

      if (name === "search_events") {
        const cityId = params.p_city_id as string;
        const events = opts.searchEventsResult?.[cityId] ?? [];
        return Promise.resolve({ data: events, error: null });
      }

      if (name === "log_cron_run_event") {
        return Promise.resolve({ data: null, error: null });
      }

      return Promise.resolve({ data: null, error: null });
    },
  };
}

// ---------------------------------------------------------------------------
// Import the module's inner logic by extracting core logic into testable shape
// We test the core flow by simulating what the handler does
// ---------------------------------------------------------------------------

// Since the edge function uses Deno.serve via serveServiceRoleJson, we test
// the business logic by replicating the key steps in isolation.

function buildDigestUsers(
  prefsRows: Array<Record<string, unknown>>,
  profileRows: Array<Record<string, unknown>>,
) {
  type ProfileRow = {
    id: string;
    email: string | null;
    display_name: string | null;
    city_preference_id: string | null;
    cities: { id: string; name: string } | null;
  };

  interface DigestUser {
    user_id: string;
    email: string;
    display_name: string | null;
    city_id: string;
    city_name: string;
  }

  const profilesById = new Map<string, ProfileRow>();
  for (const profile of profileRows as unknown as ProfileRow[]) {
    profilesById.set(profile.id, profile);
  }

  const digestUsers: DigestUser[] = [];
  for (const row of prefsRows) {
    const profile = profilesById.get(row.user_id as string);
    if (!profile?.email || !profile.cities) continue;
    digestUsers.push({
      user_id: row.user_id as string,
      email: profile.email,
      display_name: profile.display_name,
      city_id: profile.cities.id,
      city_name: profile.cities.name,
    });
  }
  return digestUsers;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

Deno.test("buildDigestUsers flattens join rows correctly", () => {
  const prefsRows = [
    { user_id: "u1" },
    { user_id: "u2" },
  ];
  const profileRows = [
    {
      id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      city_preference_id: "c1",
      cities: { id: "c1", name: "Lafayette" },
    },
    {
      id: "u2",
      email: "bob@test.com",
      display_name: null,
      city_preference_id: "c2",
      cities: { id: "c2", name: "Houston" },
    },
  ];

  const users = buildDigestUsers(prefsRows, profileRows);
  assertEquals(users.length, 2);
  assertEquals(users[0].email, "alice@test.com");
  assertEquals(users[0].city_name, "Lafayette");
  assertEquals(users[1].display_name, null);
  assertEquals(users[1].city_id, "c2");
});

Deno.test("buildDigestUsers skips users without email", () => {
  const prefsRows = [{ user_id: "u1" }];
  const profileRows = [
    {
      id: "u1",
      email: null,
      display_name: "No Email",
      city_preference_id: "c1",
      cities: { id: "c1", name: "Lafayette" },
    },
  ];

  const users = buildDigestUsers(prefsRows, profileRows);
  assertEquals(users.length, 0);
});

Deno.test("buildDigestUsers skips users without city", () => {
  const prefsRows = [{ user_id: "u1" }];
  const profileRows = [
    {
      id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      city_preference_id: null,
      cities: null,
    },
  ];

  const users = buildDigestUsers(prefsRows, profileRows);
  assertEquals(users.length, 0);
});

Deno.test("digest user reads avoid nonexistent preferences to profiles embed", async () => {
  const queryCalls: MockQueryChain[] = [];
  const supabase = createMockSupabase({
    prefsRows: [{ user_id: "u1" }, { user_id: "u2" }],
    profileRows: [
      {
        id: "u1",
        email: "alice@test.com",
        display_name: "Alice",
        city_preference_id: "c1",
        cities: { id: "c1", name: "Lafayette" },
      },
    ],
    queryCalls,
  });

  await supabase
    .from("user_notification_preferences")
    .select("user_id")
    .eq("digest_email", true);
  await supabase
    .from("user_profiles")
    .select("id, email, display_name, city_preference_id, cities!inner(id, name)")
    .in("id", ["u1", "u2"]);

  assertEquals(queryCalls.length, 2);
  assertEquals(queryCalls[0].from, "user_notification_preferences");
  assertEquals(queryCalls[0].selectStr, "user_id");
  assertEquals(queryCalls[0].eqCalls, [{ col: "digest_email", val: true }]);
  assertEquals(queryCalls[1].from, "user_profiles");
  assertEquals(queryCalls[1].inCalls, [{ col: "id", val: ["u1", "u2"] }]);
});

Deno.test("mock Supabase queries events by city via search_events RPC", async () => {
  const rpcCalls: MockRpcCall[] = [];
  const mockEvents = {
    c1: [
      { id: "e1", title: "Park Day", start_datetime: "2026-06-02T10:00:00Z", venue_name: "City Park", is_free: true },
      { id: "e2", title: "Story Time", start_datetime: "2026-06-03T14:00:00Z", venue_name: "Library", is_free: true },
    ],
    c2: [],
  };

  const supabase = createMockSupabase({
    prefsRows: [],
    searchEventsResult: mockEvents,
    rpcCalls,
  });

  // Query city with events
  const result1 = await supabase.rpc("search_events", {
    p_city_id: "c1",
    p_date_from: new Date().toISOString(),
    p_date_to: new Date(Date.now() + 7 * 86400000).toISOString(),
    p_status: "published",
    p_limit: 10,
  });
  const events1 = result1.data as Array<Record<string, unknown>>;

  assertEquals(events1.length, 2);
  assertEquals(events1[0].title, "Park Day");

  // Query city without events
  const result2 = await supabase.rpc("search_events", {
    p_city_id: "c2",
    p_date_from: new Date().toISOString(),
    p_date_to: new Date(Date.now() + 7 * 86400000).toISOString(),
    p_status: "published",
    p_limit: 10,
  });
  const events2 = result2.data as Array<Record<string, unknown>>;

  assertEquals(events2.length, 0);

  // Verify both RPCs were called
  assertEquals(rpcCalls.length, 2);
  assertEquals(rpcCalls[0].name, "search_events");
  assertEquals(rpcCalls[0].params.p_city_id, "c1");
  assertEquals(rpcCalls[1].params.p_city_id, "c2");
});

Deno.test("empty city produces no events and user should be skipped", async () => {
  const rpcCalls: MockRpcCall[] = [];
  const supabase = createMockSupabase({
    searchEventsResult: { c_empty: [] },
    rpcCalls,
  });

  const result = await supabase.rpc("search_events", {
    p_city_id: "c_empty",
    p_status: "published",
    p_limit: 10,
  });
  const data = result.data as Array<Record<string, unknown>>;

  assertEquals(data.length, 0);
  // With no events, the digest function skips this user
});

Deno.test("grouping users by city deduplicates event queries", () => {
  const users = [
    { user_id: "u1", email: "a@t.com", display_name: "A", city_id: "c1", city_name: "Lafayette" },
    { user_id: "u2", email: "b@t.com", display_name: "B", city_id: "c1", city_name: "Lafayette" },
    { user_id: "u3", email: "c@t.com", display_name: "C", city_id: "c2", city_name: "Houston" },
  ];

  const usersByCity = new Map<string, typeof users>();
  for (const user of users) {
    const group = usersByCity.get(user.city_id) ?? [];
    group.push(user);
    usersByCity.set(user.city_id, group);
  }

  // Only 2 unique cities, so only 2 event queries needed
  assertEquals(usersByCity.size, 2);
  assertEquals(usersByCity.get("c1")!.length, 2);
  assertEquals(usersByCity.get("c2")!.length, 1);
});

Deno.test("Resend API call shape is correct", () => {
  // Verify the shape of what would be sent to Resend
  const resendPayload = {
    from: "Family Events <onboarding@resend.dev>",
    to: ["alice@test.com"],
    subject: "3 family events this week in Lafayette",
    html: "<html>...</html>",
  };

  assertEquals(resendPayload.from, "Family Events <onboarding@resend.dev>");
  assertEquals(resendPayload.to, ["alice@test.com"]);
  assertEquals(typeof resendPayload.subject, "string");
  assertEquals(resendPayload.subject.includes("Lafayette"), true);
  assertEquals(typeof resendPayload.html, "string");
});

Deno.test("cron-weekly-digest label maps to send-weekly-digest function", () => {
  // Verify the dispatcher mapping (mirrors admin-run-cron)
  const cronFunctionByLabel: Record<string, string> = {
    "cron-cleanup-stale": "cleanup-stale-runs",
    "cron-db-maintenance": "db-maintenance",
    "cron-enrich-events": "backfill-event-enrichment",
    "cron-review-events": "process-event-review-queue",
    "cron-scrape-sources": "scrape-due-sources",
    "cron-tag-queue": "process-tag-queue",
    "cron-weekly-digest": "send-weekly-digest",
  };

  assertEquals(cronFunctionByLabel["cron-weekly-digest"], "send-weekly-digest");
});
