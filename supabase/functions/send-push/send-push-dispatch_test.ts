import { assertEquals } from "jsr:@std/assert"
import {
  buildApnsRequest,
  buildFcmMessage,
  mobileCredentialStatus,
  partitionMobileSubscriptions,
  type ApnsCredentials,
  type FcmCredentials,
  type PushSubscriptionRow,
} from "./lib/mobile-push.ts"

// ---------------------------------------------------------------------------
// Prune decision per provider branch (mirrors send-push/index.ts).
//
// index.ts prunes a subscription on these statuses:
//   web push  → 410, 404            (index.ts:479)
//   APNs      → 410, 400            (index.ts:544)
//   FCM       → 404, 400            (index.ts:611)
// 2xx counts as sent; anything else is a (non-pruning) failure.
// These are inline conditionals in the handler, so the decision is mirrored
// here as small pure predicates — the values are the contract under test.
// ---------------------------------------------------------------------------

function shouldPruneWeb(status: number): boolean {
  return status === 410 || status === 404
}
function shouldPruneApns(status: number): boolean {
  return status === 410 || status === 400
}
function shouldPruneFcm(status: number): boolean {
  return status === 404 || status === 400
}

Deno.test("web push prunes on 410 and 404, keeps on 2xx/other", () => {
  assertEquals(shouldPruneWeb(410), true)
  assertEquals(shouldPruneWeb(404), true)
  assertEquals(shouldPruneWeb(201), false)
  assertEquals(shouldPruneWeb(200), false)
  assertEquals(shouldPruneWeb(403), false)
  assertEquals(shouldPruneWeb(500), false)
  // 400 is NOT a web-push prune trigger (only APNs/FCM treat 400 as dead)
  assertEquals(shouldPruneWeb(400), false)
})

Deno.test("APNs prunes on 410 and 400, keeps on 2xx/other", () => {
  assertEquals(shouldPruneApns(410), true)
  assertEquals(shouldPruneApns(400), true)
  assertEquals(shouldPruneApns(200), false)
  assertEquals(shouldPruneApns(403), false)
  // 404 is NOT an APNs prune trigger
  assertEquals(shouldPruneApns(404), false)
})

Deno.test("FCM prunes on 404 and 400, keeps on 2xx/other", () => {
  assertEquals(shouldPruneFcm(404), true)
  assertEquals(shouldPruneFcm(400), true)
  assertEquals(shouldPruneFcm(200), false)
  assertEquals(shouldPruneFcm(403), false)
  // 410 is NOT an FCM prune trigger
  assertEquals(shouldPruneFcm(410), false)
})

// ---------------------------------------------------------------------------
// Platform routing — the handler splits subscriptions into web / APNs / FCM.
//   web      → handled directly in index.ts (sub.platform === "web")
//   ios      → partitionMobileSubscriptions().apns
//   android  → partitionMobileSubscriptions().fcm
// Routing of mobile rows is the real exported helper under test.
// ---------------------------------------------------------------------------

Deno.test("platform routing splits web / ios / android subscriptions", () => {
  const rows: PushSubscriptionRow[] = [
    { id: "web1", platform: "web", token: null },
    { id: "ios1", platform: "ios", token: "apns-token-1" },
    { id: "ios2", platform: "ios", token: "apns-token-2" },
    { id: "and1", platform: "android", token: "fcm-token-1" },
  ]

  // Web is selected by the handler with a direct platform filter.
  const web = rows.filter((r) => r.platform === "web")
  assertEquals(
    web.map((r) => r.id),
    ["web1"]
  )

  const mobile = partitionMobileSubscriptions(rows)
  assertEquals(
    mobile.apns.map((r) => r.id),
    ["ios1", "ios2"]
  )
  assertEquals(
    mobile.fcm.map((r) => r.id),
    ["and1"]
  )
})

Deno.test("platform routing drops mobile rows missing a token", () => {
  const rows: PushSubscriptionRow[] = [
    { id: "ios-no-token", platform: "ios", token: null },
    { id: "and-empty-token", platform: "android", token: "" },
    { id: "ios-ok", platform: "ios", token: "t" },
  ]
  const mobile = partitionMobileSubscriptions(rows)
  // Tokenless ios/android rows cannot be delivered, so they are not routed.
  assertEquals(
    mobile.apns.map((r) => r.id),
    ["ios-ok"]
  )
  assertEquals(mobile.fcm.length, 0)
})

// ---------------------------------------------------------------------------
// Provider request shaping (real exported builders).
// ---------------------------------------------------------------------------

Deno.test("buildApnsRequest targets production host and carries alert payload", () => {
  const req = buildApnsRequest({
    token: "device-token",
    jwt: "signed-jwt",
    bundleId: "com.familyevents.app",
    environment: "production",
    payload: { title: "Park Day", body: "is tomorrow", url: "https://app/events/e1" },
  })
  assertEquals(req.url, "https://api.push.apple.com/3/device/device-token")
  assertEquals(req.headers["apns-topic"], "com.familyevents.app")
  assertEquals(req.headers.authorization, "bearer signed-jwt")
  const body = JSON.parse(req.body) as {
    aps: { alert: { title: string; body: string } }
    url?: string
  }
  assertEquals(body.aps.alert.title, "Park Day")
  assertEquals(body.aps.alert.body, "is tomorrow")
  assertEquals(body.url, "https://app/events/e1")
})

Deno.test("buildApnsRequest targets sandbox host in sandbox environment", () => {
  const req = buildApnsRequest({
    token: "t",
    jwt: "j",
    bundleId: "b",
    environment: "sandbox",
    payload: { title: "T", body: "B" },
  })
  assertEquals(req.url, "https://api.sandbox.push.apple.com/3/device/t")
  const body = JSON.parse(req.body) as { url?: string }
  // No url provided → no url key in the body.
  assertEquals("url" in body, false)
})

Deno.test("buildFcmMessage carries token, notification and url data", () => {
  const msg = buildFcmMessage({
    token: "fcm-token",
    title: "Park Day",
    body: "is today",
    url: "https://app/events/e2",
  })
  assertEquals(msg.message.token, "fcm-token")
  assertEquals(msg.message.notification.title, "Park Day")
  assertEquals(msg.message.notification.body, "is today")
  assertEquals(msg.message.data.url, "https://app/events/e2")
  assertEquals(msg.message.android.priority, "HIGH")
  assertEquals(msg.message.android.notification.channel_id, "family_events")
})

Deno.test("buildFcmMessage omits url data when no url is provided", () => {
  const msg = buildFcmMessage({ token: "t", title: "T", body: "B" })
  assertEquals(msg.message.data, {})
})

// ---------------------------------------------------------------------------
// Credential gating — controls whether a provider branch dispatches at all.
// ---------------------------------------------------------------------------

Deno.test("mobileCredentialStatus reports apns ready only when all fields present", () => {
  const full: ApnsCredentials = {
    teamId: "team",
    keyId: "key",
    privateKey: "pk",
    bundleId: "bundle",
    environment: "production",
  }
  assertEquals(mobileCredentialStatus({ apns: full }).apns, true)

  const missing: ApnsCredentials = { ...full, privateKey: "" }
  assertEquals(mobileCredentialStatus({ apns: missing }).apns, false)
  assertEquals(mobileCredentialStatus({}).apns, false)
})

Deno.test("mobileCredentialStatus reports fcm ready only when all fields present", () => {
  const full: FcmCredentials = {
    projectId: "proj",
    clientEmail: "svc@proj.iam",
    privateKey: "pk",
  }
  assertEquals(mobileCredentialStatus({ fcm: full }).fcm, true)
  assertEquals(mobileCredentialStatus({ fcm: { ...full, projectId: "" } }).fcm, false)
  assertEquals(mobileCredentialStatus({}).fcm, false)
})
