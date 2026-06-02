import { assertEquals } from "jsr:@std/assert"
import {
  buildApnsRequest,
  buildFcmMessage,
  mobileCredentialStatus,
  partitionMobileSubscriptions,
  type MobilePushCredentials,
  type PushSubscriptionRow,
} from "./mobile-push.ts"

Deno.test("partitionMobileSubscriptions separates valid APNs and FCM tokens", () => {
  const rows: PushSubscriptionRow[] = [
    { id: "web", platform: "web", token: null },
    { id: "ios", platform: "ios", token: "apns-token" },
    { id: "android", platform: "android", token: "fcm-token" },
    { id: "empty", platform: "android", token: "" },
  ]

  const result = partitionMobileSubscriptions(rows)

  assertEquals(result.apns.map((row) => row.id), ["ios"])
  assertEquals(result.fcm.map((row) => row.id), ["android"])
})

Deno.test("mobileCredentialStatus reports configured APNs and FCM providers", () => {
  const credentials: MobilePushCredentials = {
    apns: {
      teamId: "TEAMID1234",
      keyId: "KEYID12345",
      privateKey: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
      bundleId: "com.familyevents.app",
      environment: "production",
    },
    fcm: {
      projectId: "family-events",
      clientEmail: "firebase-adminsdk@example.iam.gserviceaccount.com",
      privateKey: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
    },
  }

  assertEquals(mobileCredentialStatus(credentials), { apns: true, fcm: true })
})

Deno.test("buildApnsRequest targets the APNs environment and carries deep link url", () => {
  const request = buildApnsRequest({
    token: "device-token",
    jwt: "signed-jwt",
    bundleId: "com.familyevents.app",
    environment: "sandbox",
    payload: {
      title: "Reminder",
      body: "Story time starts soon",
      url: "familyevents://event/123",
    },
  })

  assertEquals(request.url, "https://api.sandbox.push.apple.com/3/device/device-token")
  assertEquals(request.headers["authorization"], "bearer signed-jwt")
  assertEquals(request.headers["apns-topic"], "com.familyevents.app")
  assertEquals(JSON.parse(request.body).url, "familyevents://event/123")
})

Deno.test("buildFcmMessage includes notification and data payload", () => {
  const message = buildFcmMessage({
    token: "fcm-token",
    title: "Event changed",
    body: "The venue changed",
    url: "familyevents://event/456",
  })

  assertEquals(message.message.token, "fcm-token")
  assertEquals(message.message.notification.title, "Event changed")
  assertEquals(message.message.data.url, "familyevents://event/456")
})
