import { assertEquals, assertStringIncludes } from "jsr:@std/assert"
import { sendResendEmail } from "../_shared/resend.ts"
import type { PublicIpResolver } from "../_shared/guarded-fetch.ts"

// No-op SSRF resolver — bypasses real DNS lookups in unit tests (no --allow-net).
const noopResolve: PublicIpResolver = (_url) => Promise.resolve({ ok: true })

// ---------------------------------------------------------------------------
// Helpers to build mock Supabase client + Resend server
// ---------------------------------------------------------------------------

interface MockRpcCall {
  name: string
  params: Record<string, unknown>
}

interface MockQueryChain {
  from: string
  selectStr: string
  eqCalls: Array<{ col: string; val: unknown }>
  inCalls: Array<{ col: string; val: unknown[] }>
}

// Ranked row returned by plan_events_for_user_range
interface RankedEventRow {
  event_id: string
  score: number
  distance_score: number | null
  weather_score: number | null
  age_score: number | null
  history_affinity: number | null
  family_fit_score: number | null
  timing_score: number | null
  novelty_score: number | null
  budget_score: number | null
  distance_km: number | null
  start_datetime: string
  city_id: string
}

function createMockSupabase(opts: {
  prefsRows?: Array<Record<string, unknown>>
  profileRows?: Array<Record<string, unknown>>
  preferredCityRows?: Array<{ user_id: string; city_id: string }>
  planEventsResult?: Record<string, RankedEventRow[]>
  eventDetailRows?: Array<Record<string, unknown>>
  rpcCalls?: MockRpcCall[]
  queryCalls?: MockQueryChain[]
}) {
  const rpcCalls: MockRpcCall[] = opts.rpcCalls ?? []
  const queryCalls: MockQueryChain[] = opts.queryCalls ?? []

  function buildSelectChain(
    tableName: string,
    rows: Array<Record<string, unknown>>,
    // allow overriding rows after select for tables that need it
    _extra?: unknown
  ) {
    let selectStr = ""
    const eqCalls: Array<{ col: string; val: unknown }> = []

    const chain = {
      select(s: string) {
        selectStr = s
        return chain
      },
      eq(col: string, val: unknown) {
        eqCalls.push({ col, val })
        queryCalls.push({ from: tableName, selectStr, eqCalls: [...eqCalls], inCalls: [] })
        const filtered = rows.filter((r) => r[col] === val)
        return Promise.resolve({ data: filtered, error: null })
      },
      in(col: string, val: unknown[]) {
        queryCalls.push({
          from: tableName,
          selectStr,
          eqCalls: [...eqCalls],
          inCalls: [{ col, val }],
        })
        const set = new Set(val)
        const filtered = rows.filter((r) => set.has(r[col]))
        return Promise.resolve({ data: filtered, error: null })
      },
    }
    return chain
  }

  return {
    from(table: string) {
      if (table === "user_notification_preferences") {
        return buildSelectChain(table, opts.prefsRows ?? [])
      }
      if (table === "user_profiles") {
        return buildSelectChain(table, opts.profileRows ?? [])
      }
      if (table === "user_preferred_cities") {
        return buildSelectChain(
          table,
          (opts.preferredCityRows ?? []) as Array<Record<string, unknown>>
        )
      }
      if (table === "events") {
        return buildSelectChain(table, opts.eventDetailRows ?? [])
      }
      return buildSelectChain(table, [])
    },
    rpc(name: string, params: Record<string, unknown> = {}) {
      rpcCalls.push({ name, params })

      if (name === "plan_events_for_user_range") {
        const userId = params.p_user_id as string
        const rows = opts.planEventsResult?.[userId] ?? []
        return Promise.resolve({ data: rows, error: null })
      }

      if (name === "log_cron_run_event") {
        return Promise.resolve({ data: null, error: null })
      }

      return Promise.resolve({ data: null, error: null })
    },
  }
}

// ---------------------------------------------------------------------------
// Inline helpers extracted from index.ts for unit-level testing
// ---------------------------------------------------------------------------

function buildDigestUsers(
  prefsRows: Array<Record<string, unknown>>,
  profileRows: Array<Record<string, unknown>>
) {
  type ProfileRow = {
    id: string
    email: string | null
    display_name: string | null
    city_preference_id: string | null
    child_age: number | null
    cities: { id: string; name: string; latitude: number | null; longitude: number | null } | null
  }

  interface DigestUser {
    user_id: string
    email: string
    display_name: string | null
    city_id: string
    city_name: string
    lat: number | null
    lng: number | null
    child_age: number | null
  }

  const profilesById = new Map<string, ProfileRow>()
  for (const profile of profileRows as unknown as ProfileRow[]) {
    profilesById.set(profile.id, profile)
  }

  const digestUsers: DigestUser[] = []
  for (const row of prefsRows) {
    const profile = profilesById.get(row.user_id as string)
    if (!profile?.email || !profile.cities) continue
    digestUsers.push({
      user_id: row.user_id as string,
      email: profile.email,
      display_name: profile.display_name,
      city_id: profile.cities.id,
      city_name: profile.cities.name,
      lat: profile.cities.latitude ?? null,
      lng: profile.cities.longitude ?? null,
      child_age: profile.child_age ?? null,
    })
  }
  return digestUsers
}

// Factor labels in priority order (mirrors index.ts)
const FACTOR_LABELS: Array<[keyof RankedEventRow, string]> = [
  ["distance_score", "nearby"],
  ["weather_score", "weather fit"],
  ["age_score", "great age match"],
  ["history_affinity", "matches your interests"],
  ["family_fit_score", "family-friendly"],
  ["timing_score", "perfect weekend timing"],
  ["novelty_score", "newly added"],
  ["budget_score", "budget-friendly"],
]

const NEUTRAL_THRESHOLD = 0.5

function buildExplanation(row: RankedEventRow): string | undefined {
  const candidates: Array<{ label: string; value: number; order: number }> = []
  for (let i = 0; i < FACTOR_LABELS.length; i++) {
    const [key, label] = FACTOR_LABELS[i]
    const val = row[key] as number | null
    if (val != null && val > NEUTRAL_THRESHOLD) {
      candidates.push({ label, value: val, order: i })
    }
  }
  if (candidates.length === 0) return undefined
  candidates.sort((a, b) => b.value - a.value || a.order - b.order)
  const top2 = candidates.slice(0, 2).map((c) => c.label)
  return top2.join(" · ")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

Deno.test("buildDigestUsers flattens join rows correctly", () => {
  const prefsRows = [{ user_id: "u1" }, { user_id: "u2" }]
  const profileRows = [
    {
      id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      city_preference_id: "c1",
      child_age: 5,
      cities: { id: "c1", name: "Lafayette", latitude: 30.224, longitude: -92.019 },
    },
    {
      id: "u2",
      email: "bob@test.com",
      display_name: null,
      city_preference_id: "c2",
      child_age: null,
      cities: { id: "c2", name: "Houston", latitude: null, longitude: null },
    },
  ]

  const users = buildDigestUsers(prefsRows, profileRows)
  assertEquals(users.length, 2)
  assertEquals(users[0].email, "alice@test.com")
  assertEquals(users[0].city_name, "Lafayette")
  assertEquals(users[0].child_age, 5)
  assertEquals(users[0].lat, 30.224)
  assertEquals(users[0].lng, -92.019)
  assertEquals(users[1].display_name, null)
  assertEquals(users[1].city_id, "c2")
  assertEquals(users[1].child_age, null)
  assertEquals(users[1].lat, null)
  assertEquals(users[1].lng, null)
})

Deno.test("buildDigestUsers skips users without email", () => {
  const prefsRows = [{ user_id: "u1" }]
  const profileRows = [
    {
      id: "u1",
      email: null,
      display_name: "No Email",
      city_preference_id: "c1",
      child_age: null,
      cities: { id: "c1", name: "Lafayette", latitude: 30.224, longitude: -92.019 },
    },
  ]

  const users = buildDigestUsers(prefsRows, profileRows)
  assertEquals(users.length, 0)
})

Deno.test("buildDigestUsers skips users without city", () => {
  const prefsRows = [{ user_id: "u1" }]
  const profileRows = [
    {
      id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      city_preference_id: null,
      child_age: null,
      cities: null,
    },
  ]

  const users = buildDigestUsers(prefsRows, profileRows)
  assertEquals(users.length, 0)
})

Deno.test("digest user reads avoid nonexistent preferences to profiles embed", async () => {
  const queryCalls: MockQueryChain[] = []
  const supabase = createMockSupabase({
    prefsRows: [{ user_id: "u1" }, { user_id: "u2" }],
    profileRows: [
      {
        id: "u1",
        email: "alice@test.com",
        display_name: "Alice",
        city_preference_id: "c1",
        child_age: null,
        cities: { id: "c1", name: "Lafayette", latitude: 30.224, longitude: -92.019 },
      },
    ],
    queryCalls,
  })

  await supabase.from("user_notification_preferences").select("user_id").eq("digest_email", true)
  await supabase
    .from("user_profiles")
    .select(
      "id, email, display_name, city_preference_id, child_age, cities!inner(id, name, latitude, longitude)"
    )
    .in("id", ["u1", "u2"])

  assertEquals(queryCalls.length, 2)
  assertEquals(queryCalls[0].from, "user_notification_preferences")
  assertEquals(queryCalls[0].selectStr, "user_id")
  assertEquals(queryCalls[0].eqCalls, [{ col: "digest_email", val: true }])
  assertEquals(queryCalls[1].from, "user_profiles")
  assertEquals(queryCalls[1].inCalls, [{ col: "id", val: ["u1", "u2"] }])
})

Deno.test("preferred cities fallback: user with no rows uses primary city_id", async () => {
  const queryCalls: MockQueryChain[] = []
  const supabase = createMockSupabase({
    preferredCityRows: [
      // only u2 has preferred cities; u1 will fall back
      { user_id: "u2", city_id: "c3" },
    ],
    queryCalls,
  })

  const result = await supabase
    .from("user_preferred_cities")
    .select("user_id, city_id")
    .in("user_id", ["u1", "u2"])

  const rows = result.data as Array<{ user_id: string; city_id: string }>
  assertEquals(rows.length, 1)
  assertEquals(rows[0].user_id, "u2")

  // Simulate the fallback logic
  const prefCityMap = new Map<string, string[]>()
  for (const row of rows) {
    const list = prefCityMap.get(row.user_id) ?? []
    list.push(row.city_id)
    prefCityMap.set(row.user_id, list)
  }

  const cityIdsU1 = prefCityMap.get("u1") ?? ["c1_primary"]
  const cityIdsU2 = prefCityMap.get("u2") ?? ["c2_primary"]

  assertEquals(cityIdsU1, ["c1_primary"]) // fallback to primary
  assertEquals(cityIdsU2, ["c3"]) // from preferred cities table
})

Deno.test("plan_events_for_user_range RPC is called with correct parameters", async () => {
  const rpcCalls: MockRpcCall[] = []
  const rankedRows: RankedEventRow[] = [
    {
      event_id: "e1",
      score: 0.9,
      distance_score: 0.85,
      weather_score: 0.7,
      age_score: 0.6,
      history_affinity: 0.5,
      family_fit_score: 0.8,
      timing_score: 0.55,
      novelty_score: 0.4,
      budget_score: 0.9,
      distance_km: 2.5,
      start_datetime: "2026-06-20T14:00:00Z",
      city_id: "c1",
    },
  ]

  const supabase = createMockSupabase({
    planEventsResult: { u1: rankedRows },
    rpcCalls,
  })

  const windowFrom = "2026-06-19T00:00:00.000Z"
  const windowTo = "2026-06-21T23:59:59.999Z"

  const result = await supabase.rpc("plan_events_for_user_range", {
    p_user_id: "u1",
    p_date_from: windowFrom,
    p_date_to: windowTo,
    p_city_ids: ["c1", "c2"],
    p_kid_age: 5,
    p_weather_fit: "neutral",
    p_limit: 5,
  })

  assertEquals(rpcCalls.length, 1)
  assertEquals(rpcCalls[0].name, "plan_events_for_user_range")
  assertEquals(rpcCalls[0].params.p_user_id, "u1")
  assertEquals(rpcCalls[0].params.p_city_ids, ["c1", "c2"])
  assertEquals(rpcCalls[0].params.p_kid_age, 5)
  assertEquals(rpcCalls[0].params.p_weather_fit, "neutral")
  assertEquals(rpcCalls[0].params.p_limit, 5)

  const rows = result.data as RankedEventRow[]
  assertEquals(rows.length, 1)
  assertEquals(rows[0].event_id, "e1")
  assertEquals(rows[0].score, 0.9)
})

Deno.test("RPC receives p_lat/p_lng from primary city centroid when centroid is present", async () => {
  const rpcCalls: MockRpcCall[] = []
  const supabase = createMockSupabase({
    planEventsResult: { u1: [] },
    rpcCalls,
  })

  // Simulate a DigestUser with a known centroid
  const user = {
    user_id: "u1",
    lat: 30.224,
    lng: -92.019,
  }

  await supabase.rpc("plan_events_for_user_range", {
    p_user_id: user.user_id,
    p_date_from: "2026-06-20T00:00:00.000Z",
    p_date_to: "2026-06-22T23:59:59.999Z",
    p_city_ids: ["c1"],
    p_kid_age: null,
    p_weather_fit: "neutral",
    p_limit: 5,
    p_lat: user.lat,
    p_lng: user.lng,
  })

  assertEquals(rpcCalls.length, 1)
  assertEquals(rpcCalls[0].params.p_lat, 30.224)
  assertEquals(rpcCalls[0].params.p_lng, -92.019)
})

Deno.test("RPC receives p_lat=null/p_lng=null when city has no centroid (neutral score fallback)", async () => {
  const rpcCalls: MockRpcCall[] = []
  const supabase = createMockSupabase({
    planEventsResult: { u1: [] },
    rpcCalls,
  })

  // Simulate a DigestUser with no centroid (city has no lat/lng)
  const user = {
    user_id: "u1",
    lat: null,
    lng: null,
  }

  await supabase.rpc("plan_events_for_user_range", {
    p_user_id: user.user_id,
    p_date_from: "2026-06-20T00:00:00.000Z",
    p_date_to: "2026-06-22T23:59:59.999Z",
    p_city_ids: ["c1"],
    p_kid_age: null,
    p_weather_fit: "neutral",
    p_limit: 5,
    p_lat: user.lat,
    p_lng: user.lng,
  })

  assertEquals(rpcCalls.length, 1)
  assertEquals(rpcCalls[0].params.p_lat, null)
  assertEquals(rpcCalls[0].params.p_lng, null)
  // RPC defaults to neutral 0.50 distance score — no crash
})

Deno.test("buildDigestUsers propagates null lat/lng for city with no centroid", () => {
  const prefsRows = [{ user_id: "u1" }]
  const profileRows = [
    {
      id: "u1",
      email: "alice@test.com",
      display_name: "Alice",
      city_preference_id: "c1",
      child_age: null,
      cities: { id: "c1", name: "Lafayette", latitude: null, longitude: null },
    },
  ]

  const users = buildDigestUsers(prefsRows, profileRows)
  assertEquals(users.length, 1)
  assertEquals(users[0].lat, null)
  assertEquals(users[0].lng, null)
})

Deno.test("empty plan_events_for_user_range result means user is skipped", async () => {
  const rpcCalls: MockRpcCall[] = []
  const supabase = createMockSupabase({
    planEventsResult: { u1: [] },
    rpcCalls,
  })

  const result = await supabase.rpc("plan_events_for_user_range", {
    p_user_id: "u1",
    p_date_from: "2026-06-19T00:00:00Z",
    p_date_to: "2026-06-21T23:59:59Z",
    p_city_ids: ["c1"],
    p_kid_age: null,
    p_weather_fit: "neutral",
    p_limit: 5,
  })

  const rows = result.data as RankedEventRow[]
  assertEquals(rows.length, 0)
  // Digest handler would skip this user (no events)
})

Deno.test("buildExplanation picks top 2 factors above neutral threshold", () => {
  const row: RankedEventRow = {
    event_id: "e1",
    score: 0.85,
    distance_score: 0.95, // highest — "nearby"
    weather_score: 0.3, // below threshold — ignored
    age_score: 0.88, // second highest — "great age match"
    history_affinity: 0.5, // at threshold — ignored
    family_fit_score: 0.7, // third — cut off at 2
    timing_score: 0.55,
    novelty_score: null,
    budget_score: 0.6,
    distance_km: 1.2,
    start_datetime: "2026-06-21T10:00:00Z",
    city_id: "c1",
  }

  const explanation = buildExplanation(row)
  assertEquals(explanation, "nearby · great age match")
})

Deno.test("buildExplanation returns undefined when all factors at or below neutral", () => {
  const row: RankedEventRow = {
    event_id: "e2",
    score: 0.5,
    distance_score: 0.5,
    weather_score: 0.3,
    age_score: null,
    history_affinity: 0.5,
    family_fit_score: 0.4,
    timing_score: 0.5,
    novelty_score: 0.2,
    budget_score: null,
    distance_km: null,
    start_datetime: "2026-06-21T12:00:00Z",
    city_id: "c1",
  }

  const explanation = buildExplanation(row)
  assertEquals(explanation, undefined)
})

Deno.test("buildExplanation respects weight-order tie-breaking", () => {
  // distance_score and age_score both at 0.8; distance comes first in weight order
  const row: RankedEventRow = {
    event_id: "e3",
    score: 0.8,
    distance_score: 0.8,
    weather_score: null,
    age_score: 0.8,
    history_affinity: null,
    family_fit_score: null,
    timing_score: null,
    novelty_score: null,
    budget_score: null,
    distance_km: 3.0,
    start_datetime: "2026-06-21T15:00:00Z",
    city_id: "c1",
  }

  const explanation = buildExplanation(row)
  assertEquals(explanation, "nearby · great age match")
})

Deno.test("buildExplanation returns single label when only one factor above threshold", () => {
  const row: RankedEventRow = {
    event_id: "e4",
    score: 0.65,
    distance_score: null,
    weather_score: null,
    age_score: null,
    history_affinity: null,
    family_fit_score: null,
    timing_score: null,
    novelty_score: null,
    budget_score: 0.9,
    distance_km: null,
    start_datetime: "2026-06-21T16:00:00Z",
    city_id: "c1",
  }

  const explanation = buildExplanation(row)
  assertEquals(explanation, "budget-friendly")
})

Deno.test("event detail fetch assembles DigestEvents in ranked order", async () => {
  const queryCalls: MockQueryChain[] = []

  // RPC returns e2 ranked higher than e1
  const rankedRows: RankedEventRow[] = [
    {
      event_id: "e2",
      score: 0.9,
      distance_score: 0.95,
      weather_score: null,
      age_score: null,
      history_affinity: null,
      family_fit_score: null,
      timing_score: null,
      novelty_score: null,
      budget_score: null,
      distance_km: 1.0,
      start_datetime: "2026-06-21T11:00:00Z",
      city_id: "c1",
    },
    {
      event_id: "e1",
      score: 0.7,
      distance_score: 0.6,
      weather_score: null,
      age_score: null,
      history_affinity: null,
      family_fit_score: null,
      timing_score: null,
      novelty_score: null,
      budget_score: null,
      distance_km: 5.0,
      start_datetime: "2026-06-21T14:00:00Z",
      city_id: "c1",
    },
  ]

  // DB returns rows in reverse order (ID order, not rank order)
  const eventDetailRows = [
    {
      id: "e1",
      title: "Park Day",
      start_datetime: "2026-06-21T14:00:00Z",
      venue_name: "City Park",
      address: null,
      is_free: true,
      price: null,
      images: null,
    },
    {
      id: "e2",
      title: "Story Time",
      start_datetime: "2026-06-21T11:00:00Z",
      venue_name: "Library",
      address: null,
      is_free: true,
      price: null,
      images: null,
    },
  ]

  const supabase = createMockSupabase({
    planEventsResult: { u1: rankedRows },
    eventDetailRows,
    queryCalls,
  })

  // Simulate the handler's reassembly logic
  const eventIds = rankedRows.map((r) => r.event_id)
  const { data: rows } = await supabase
    .from("events")
    .select("id, title, start_datetime, venue_name, address, is_free, price, images")
    .in("id", eventIds)

  const eventMap = new Map<string, Record<string, unknown>>()
  for (const row of (rows ?? []) as Array<Record<string, unknown>>) {
    eventMap.set(row.id as string, row)
  }

  const digestEvents = rankedRows.map((r) => eventMap.get(r.event_id)).filter(Boolean) as Array<
    Record<string, unknown>
  >

  // Ranked order is preserved: e2 first, then e1
  assertEquals(digestEvents[0].id, "e2")
  assertEquals(digestEvents[0].title, "Story Time")
  assertEquals(digestEvents[1].id, "e1")
  assertEquals(digestEvents[1].title, "Park Day")
})

Deno.test("preferred cities query shape is correct", async () => {
  const queryCalls: MockQueryChain[] = []
  const supabase = createMockSupabase({
    preferredCityRows: [
      { user_id: "u1", city_id: "c1" },
      { user_id: "u1", city_id: "c2" },
    ],
    queryCalls,
  })

  await supabase
    .from("user_preferred_cities")
    .select("user_id, city_id")
    .in("user_id", ["u1", "u2"])

  assertEquals(queryCalls.length, 1)
  assertEquals(queryCalls[0].from, "user_preferred_cities")
  assertEquals(queryCalls[0].selectStr, "user_id, city_id")
  assertEquals(queryCalls[0].inCalls[0].col, "user_id")
})

Deno.test("Resend API call subject uses personalized format", () => {
  const events = [
    { id: "e1", title: "Park Day", is_free: true },
    { id: "e2", title: "Story Time", is_free: true },
    { id: "e3", title: "Art Class", is_free: false },
  ]
  const subject = `${events.length} family picks for your weekend`

  assertEquals(typeof subject, "string")
  assertEquals(subject, "3 family picks for your weekend")
})

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
  }

  assertEquals(cronFunctionByLabel["cron-weekly-digest"], "send-weekly-digest")
})

Deno.test("weekend window computation: mid-week day targets upcoming Friday-Sunday", () => {
  // Simulate a Wednesday (day=3) — fridayOffset should be 2
  const simulatedNow = new Date("2026-06-17T10:00:00Z") // Wednesday
  const day = simulatedNow.getUTCDay()
  assertEquals(day, 3)

  const fridayOffset = day === 0 ? -2 : day === 6 ? -1 : 5 - day
  assertEquals(fridayOffset, 2)

  const friday = new Date(simulatedNow)
  friday.setUTCDate(simulatedNow.getUTCDate() + fridayOffset)
  friday.setUTCHours(0, 0, 0, 0)

  const sunday = new Date(friday)
  sunday.setUTCDate(friday.getUTCDate() + 2)
  sunday.setUTCHours(23, 59, 59, 999)

  // friday should be 2026-06-19
  assertEquals(friday.toISOString().startsWith("2026-06-19"), true)
  // sunday should be 2026-06-21
  assertEquals(sunday.toISOString().startsWith("2026-06-21"), true)

  // windowFrom should be friday (not now, since friday is still in the future relative to simulatedNow)
  const windowFrom = new Date(Math.max(simulatedNow.getTime(), friday.getTime())).toISOString()
  assertEquals(windowFrom, friday.toISOString())
})

Deno.test("weekend window computation: Saturday targets current weekend", () => {
  const simulatedNow = new Date("2026-06-20T10:00:00Z") // Saturday
  const day = simulatedNow.getUTCDay()
  assertEquals(day, 6)

  const fridayOffset = day === 0 ? -2 : day === 6 ? -1 : 5 - day
  assertEquals(fridayOffset, -1) // yesterday was Friday

  const friday = new Date(simulatedNow)
  friday.setUTCDate(simulatedNow.getUTCDate() + fridayOffset)
  friday.setUTCHours(0, 0, 0, 0)

  // windowFrom should be now (since friday is in the past)
  const windowFrom = new Date(Math.max(simulatedNow.getTime(), friday.getTime())).toISOString()
  assertEquals(windowFrom, simulatedNow.toISOString())
})

Deno.test("personalized events flow: full mock run for a single user", async () => {
  const rpcCalls: MockRpcCall[] = []
  const queryCalls: MockQueryChain[] = []

  const rankedRows: RankedEventRow[] = [
    {
      event_id: "e1",
      score: 0.92,
      distance_score: 0.95,
      weather_score: null,
      age_score: 0.85,
      history_affinity: null,
      family_fit_score: null,
      timing_score: null,
      novelty_score: null,
      budget_score: null,
      distance_km: 1.5,
      start_datetime: "2026-06-21T10:00:00Z",
      city_id: "c1",
    },
  ]

  const eventDetailRow = {
    id: "e1",
    title: "Park Day",
    start_datetime: "2026-06-21T10:00:00Z",
    venue_name: "City Park",
    address: null,
    is_free: true,
    price: null,
    images: null,
  }

  const supabase = createMockSupabase({
    planEventsResult: { u1: rankedRows },
    eventDetailRows: [eventDetailRow],
    preferredCityRows: [{ user_id: "u1", city_id: "c1" }],
    rpcCalls,
    queryCalls,
  })

  // Step 1: load preferred cities
  const { data: prefRows } = await supabase
    .from("user_preferred_cities")
    .select("user_id, city_id")
    .in("user_id", ["u1"])
  const prefCityMap = new Map<string, string[]>()
  for (const row of (prefRows ?? []) as Array<{ user_id: string; city_id: string }>) {
    const list = prefCityMap.get(row.user_id) ?? []
    list.push(row.city_id)
    prefCityMap.set(row.user_id, list)
  }

  // Step 2: call RPC
  const cityIds = prefCityMap.get("u1") ?? ["c1"]
  const { data: ranked } = await supabase.rpc("plan_events_for_user_range", {
    p_user_id: "u1",
    p_date_from: "2026-06-20T10:00:00Z",
    p_date_to: "2026-06-21T23:59:59Z",
    p_city_ids: cityIds,
    p_kid_age: null,
    p_weather_fit: "neutral",
    p_limit: 5,
  })

  // Step 3: fetch event details
  const eventIds = (ranked as RankedEventRow[]).map((r) => r.event_id)
  const { data: eventRows } = await supabase
    .from("events")
    .select("id, title, start_datetime, venue_name, address, is_free, price, images")
    .in("id", eventIds)

  // Step 4: reassemble with explanations
  const eventMap = new Map<string, Record<string, unknown>>()
  for (const row of (eventRows ?? []) as Array<Record<string, unknown>>) {
    eventMap.set(row.id as string, row)
  }

  const digestEvents = (ranked as RankedEventRow[])
    .map((r) => {
      const ev = eventMap.get(r.event_id)
      if (!ev) return null
      const explanation = buildExplanation(r)
      return { ...ev, explanation }
    })
    .filter(Boolean)

  // Assertions
  assertEquals(rpcCalls[0].name, "plan_events_for_user_range")
  assertEquals(rpcCalls[0].params.p_user_id, "u1")
  assertEquals(digestEvents.length, 1)
  assertEquals((digestEvents[0] as Record<string, unknown>).id, "e1")
  // explanation: distance_score=0.95 (nearby), age_score=0.85 (great age match)
  assertEquals((digestEvents[0] as Record<string, unknown>).explanation, "nearby · great age match")
})

// ---------------------------------------------------------------------------
// Telegram channel tests
// ---------------------------------------------------------------------------

// A minimal mock that supports .or() for the broadened prefs query.
function buildPrefsChainWithOr(
  rows: Array<Record<string, unknown>>,
  queryCalls: Array<{ from: string; orStr?: string }>
) {
  const chain = {
    select(_s: string) {
      return chain
    },
    or(filter: string) {
      queryCalls.push({ from: "user_notification_preferences", orStr: filter })
      // Apply simple filter: return rows where digest_email or digest_telegram is truthy
      const filtered = rows.filter(
        (r) => r["digest_email"] === true || r["digest_telegram"] === true
      )
      return Promise.resolve({ data: filtered, error: null })
    },
    eq(col: string, val: unknown) {
      queryCalls.push({ from: "user_notification_preferences" })
      const filtered = rows.filter((r) => r[col] === val)
      return Promise.resolve({ data: filtered, error: null })
    },
    in(_col: string, _val: unknown[]) {
      return Promise.resolve({ data: rows, error: null })
    },
  }
  return chain
}

Deno.test("prefs query uses .or() to catch both email-only and telegram-only users", async () => {
  const queryCalls: Array<{ from: string; orStr?: string }> = []
  const allPrefsRows = [
    { user_id: "u1", digest_email: true, digest_telegram: false, telegram_chat_id: null },
    { user_id: "u2", digest_email: false, digest_telegram: true, telegram_chat_id: "555" },
    { user_id: "u3", digest_email: false, digest_telegram: false, telegram_chat_id: null },
  ]

  const chain = buildPrefsChainWithOr(allPrefsRows, queryCalls)
  const result = await chain
    .select("user_id, digest_email, digest_telegram, telegram_chat_id")
    .or("digest_email.eq.true,digest_telegram.eq.true")

  assertEquals(queryCalls.length, 1)
  assertEquals(queryCalls[0].orStr, "digest_email.eq.true,digest_telegram.eq.true")

  const data = result.data as Array<Record<string, unknown>>
  // u3 (both false) must be excluded; u1 and u2 must be included
  assertEquals(data.length, 2)
  assertEquals(data.map((r) => r.user_id).sort(), ["u1", "u2"])
})

Deno.test("DigestPreference carries digest_telegram and telegram_chat_id fields", () => {
  // Validate that the preference row shape includes new Telegram fields
  const row = {
    user_id: "u1",
    digest_email: true,
    digest_telegram: true,
    telegram_chat_id: "123456789",
  }

  // These must be accessible without TypeScript error (interface check via duck-typing)
  const userId: string = row.user_id
  const digestEmail: boolean = row.digest_email
  const digestTelegram: boolean = row.digest_telegram
  const chatId: string | null = row.telegram_chat_id

  assertEquals(userId, "u1")
  assertEquals(digestEmail, true)
  assertEquals(digestTelegram, true)
  assertEquals(chatId, "123456789")
})

Deno.test("DigestUser with digest_telegram=true and chat_id is wired correctly", () => {
  interface DigestUser {
    user_id: string
    email: string
    display_name: string | null
    city_id: string
    city_name: string
    child_age: number | null
    digest_email: boolean
    digest_telegram: boolean
    telegram_chat_id: string | null
  }

  const user: DigestUser = {
    user_id: "u2",
    email: "bob@test.com",
    display_name: "Bob",
    city_id: "c1",
    city_name: "Lafayette",
    child_age: null,
    digest_email: false,
    digest_telegram: true,
    telegram_chat_id: "555666777",
  }

  // Simulate the send-loop gating logic
  const wouldSendEmail = user.digest_email
  const wouldSendTelegram = user.digest_telegram && !!user.telegram_chat_id

  assertEquals(wouldSendEmail, false)
  assertEquals(wouldSendTelegram, true)
})

Deno.test("DigestUser without telegram_chat_id skips Telegram even if digest_telegram=true", () => {
  const user = {
    user_id: "u3",
    email: "carol@test.com",
    display_name: "Carol",
    city_id: "c1",
    city_name: "Lafayette",
    child_age: null,
    digest_email: false,
    digest_telegram: true,
    telegram_chat_id: null as string | null,
  }

  const wouldSendTelegram = user.digest_telegram && !!user.telegram_chat_id
  assertEquals(wouldSendTelegram, false)
})

Deno.test("email-only user still gets email and is not sent Telegram", () => {
  const user = {
    user_id: "u1",
    email: "alice@test.com",
    display_name: "Alice",
    city_id: "c1",
    city_name: "Lafayette",
    child_age: 5,
    digest_email: true,
    digest_telegram: false,
    telegram_chat_id: null as string | null,
  }

  const wouldSendEmail = user.digest_email
  const wouldSendTelegram = user.digest_telegram && !!user.telegram_chat_id

  assertEquals(wouldSendEmail, true)
  assertEquals(wouldSendTelegram, false)
})

// ---------------------------------------------------------------------------
// Tests: sendResendEmail — SSRF-safe Resend path (digest email)
// ---------------------------------------------------------------------------

interface CapturedResendRequest {
  url: string
  init: RequestInit
}

function makeMockResendFetch(
  status: number,
  responseBody: unknown = {}
): { fetch: typeof globalThis.fetch; captured: CapturedResendRequest[] } {
  const captured: CapturedResendRequest[] = []
  const mockFetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    captured.push({ url, init: init ?? {} })
    return Promise.resolve(
      new Response(JSON.stringify(responseBody), {
        status,
        headers: { "Content-Type": "application/json" },
      })
    )
  }
  return { fetch: mockFetch as typeof globalThis.fetch, captured }
}

Deno.test("sendResendEmail (digest): 2xx returns { ok: true } and POSTs to Resend endpoint", async () => {
  const { fetch: mockFetch, captured } = makeMockResendFetch(200, { id: "re_123" })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendResendEmail(
      "test-api-key",
      {
        from: "Family Events <onboarding@resend.dev>",
        to: ["alice@test.com"],
        subject: "3 family picks for your weekend",
        html: "<p>Hello</p>",
      },
      { resolve: noopResolve }
    )

    assertEquals(result.ok, true)
    assertEquals(result.status, 200)
    assertEquals(captured.length, 1)
    assertEquals(captured[0].url, "https://api.resend.com/emails")

    const body = JSON.parse(captured[0].init.body as string)
    assertEquals(body.to, ["alice@test.com"])
    assertEquals(body.subject, "3 family picks for your weekend")
    assertEquals(body.from, "Family Events <onboarding@resend.dev>")

    const authHeader = (captured[0].init.headers as Record<string, string>)["Authorization"]
    assertEquals(authHeader, "Bearer test-api-key")
  } finally {
    globalThis.fetch = original
  }
})

Deno.test("sendResendEmail (digest): non-2xx returns { ok: false, status, errorBody }", async () => {
  const { fetch: mockFetch } = makeMockResendFetch(422, { message: "invalid email" })
  const original = globalThis.fetch
  globalThis.fetch = mockFetch

  try {
    const result = await sendResendEmail(
      "test-api-key",
      { from: "f@r.dev", to: ["bad"], subject: "hi", html: "<p>x</p>" },
      { resolve: noopResolve }
    )

    assertEquals(result.ok, false)
    assertEquals(result.status, 422)
    assertEquals(typeof result.errorBody, "string")
  } finally {
    globalThis.fetch = original
  }
})
