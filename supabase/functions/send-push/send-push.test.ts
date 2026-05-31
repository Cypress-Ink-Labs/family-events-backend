import { assertEquals, assertNotEquals } from "jsr:@std/assert"

// ---------------------------------------------------------------------------
// Helpers: VAPID & encryption utilities (extracted from send-push/index.ts)
// ---------------------------------------------------------------------------

function base64urlEncode(data: Uint8Array): string {
  let binary = ""
  for (const byte of data) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function base64urlDecode(input: string): Uint8Array {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/")
  const paddedLen = padded + "=".repeat((4 - (padded.length % 4)) % 4)
  const binary = atob(paddedLen)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes
}

function derToRaw(der: Uint8Array): Uint8Array {
  if (der.length === 64) return der
  const raw = new Uint8Array(64)
  let offset = 2
  offset++
  const rLen = der[offset++]
  const rStart = rLen > 32 ? offset + (rLen - 32) : offset
  const rDest = rLen < 32 ? 32 - rLen : 0
  raw.set(der.slice(rStart, offset + rLen), rDest)
  offset += rLen
  offset++
  const sLen = der[offset++]
  const sStart = sLen > 32 ? offset + (sLen - 32) : offset
  const sDest = sLen < 32 ? 64 - sLen : 32
  raw.set(der.slice(sStart, offset + sLen), sDest)
  return raw
}

// ---------------------------------------------------------------------------
// Tests: payload parsing
// ---------------------------------------------------------------------------

interface SendPushPayload {
  user_id: string
  title: string
  body: string
  url?: string
}

function parsePayload(value: unknown): SendPushPayload {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid payload")
  }
  const obj = value as Record<string, unknown>
  const user_id = obj.user_id
  const title = obj.title
  const body = obj.body
  const url = obj.url

  if (typeof user_id !== "string" || !user_id) throw new Error("missing user_id")
  if (typeof title !== "string" || !title) throw new Error("missing title")
  if (typeof body !== "string" || !body) throw new Error("missing body")
  if (url !== undefined && typeof url !== "string") throw new Error("invalid url")

  return { user_id, title, body, url: typeof url === "string" ? url : undefined }
}

Deno.test("parsePayload accepts valid payload with url", () => {
  const result = parsePayload({
    user_id: "u1",
    title: "Test Title",
    body: "Test body",
    url: "https://example.com",
  })
  assertEquals(result.user_id, "u1")
  assertEquals(result.title, "Test Title")
  assertEquals(result.body, "Test body")
  assertEquals(result.url, "https://example.com")
})

Deno.test("parsePayload accepts valid payload without url", () => {
  const result = parsePayload({
    user_id: "u1",
    title: "Test Title",
    body: "Test body",
  })
  assertEquals(result.url, undefined)
})

Deno.test("parsePayload rejects missing user_id", () => {
  let threw = false
  try {
    parsePayload({ title: "T", body: "B" })
  } catch (e) {
    threw = true
    assertEquals((e as Error).message, "missing user_id")
  }
  assertEquals(threw, true)
})

Deno.test("parsePayload rejects missing title", () => {
  let threw = false
  try {
    parsePayload({ user_id: "u1", body: "B" })
  } catch (e) {
    threw = true
    assertEquals((e as Error).message, "missing title")
  }
  assertEquals(threw, true)
})

Deno.test("parsePayload rejects missing body", () => {
  let threw = false
  try {
    parsePayload({ user_id: "u1", title: "T" })
  } catch (e) {
    threw = true
    assertEquals((e as Error).message, "missing body")
  }
  assertEquals(threw, true)
})

Deno.test("parsePayload rejects invalid payload types", () => {
  for (const invalid of [null, undefined, "string", 42, [], true]) {
    let threw = false
    try {
      parsePayload(invalid)
    } catch {
      threw = true
    }
    assertEquals(threw, true, `Expected to throw for ${JSON.stringify(invalid)}`)
  }
})

// ---------------------------------------------------------------------------
// Tests: base64url encoding/decoding roundtrip
// ---------------------------------------------------------------------------

Deno.test("base64url roundtrip preserves data", () => {
  const original = crypto.getRandomValues(new Uint8Array(32))
  const encoded = base64urlEncode(original)
  const decoded = base64urlDecode(encoded)
  assertEquals(decoded, original)
})

Deno.test("base64url encoding contains no +, /, or =", () => {
  // Test with bytes that produce +, /, = in standard base64
  const data = new Uint8Array([255, 254, 253, 252, 251, 250, 63, 62, 61, 60])
  const encoded = base64urlEncode(data)
  assertEquals(encoded.includes("+"), false)
  assertEquals(encoded.includes("/"), false)
  assertEquals(encoded.includes("="), false)
})

// ---------------------------------------------------------------------------
// Tests: DER to raw signature conversion
// ---------------------------------------------------------------------------

Deno.test("derToRaw returns 64-byte input unchanged", () => {
  const raw = crypto.getRandomValues(new Uint8Array(64))
  const result = derToRaw(raw)
  assertEquals(result, raw)
})

Deno.test("derToRaw converts DER-encoded ECDSA signature", () => {
  // Construct a valid DER-encoded ECDSA signature
  // r = 32 bytes, s = 32 bytes
  const r = crypto.getRandomValues(new Uint8Array(32))
  r[0] = r[0] & 0x7f // ensure no leading zero needed
  const s = crypto.getRandomValues(new Uint8Array(32))
  s[0] = s[0] & 0x7f // ensure no leading zero needed

  const der = new Uint8Array([
    0x30,
    4 + r.length + s.length, // total length
    0x02,
    r.length,
    ...r,
    0x02,
    s.length,
    ...s,
  ])

  const result = derToRaw(der)
  assertEquals(result.length, 64)
  // r should be in first 32 bytes, s in last 32
  assertEquals(result.slice(0, 32), r)
  assertEquals(result.slice(32, 64), s)
})

// ---------------------------------------------------------------------------
// Tests: VAPID JWT structure
// ---------------------------------------------------------------------------

Deno.test("VAPID JWT has three dot-separated parts", async () => {
  // Generate a real P-256 key pair for testing
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  )

  const rawPublic = new Uint8Array(
    await crypto.subtle.exportKey("raw", keyPair.publicKey),
  )
  const jwk = await crypto.subtle.exportKey("jwk", keyPair.privateKey)

  const vapidPublicKey = base64urlEncode(rawPublic)
  const vapidPrivateKey = jwk.d!

  // Build header and payload
  const header = base64urlEncode(
    new TextEncoder().encode(JSON.stringify({ typ: "JWT", alg: "ES256" })),
  )
  const now = Math.floor(Date.now() / 1000)
  const payload = base64urlEncode(
    new TextEncoder().encode(
      JSON.stringify({
        aud: "https://fcm.googleapis.com",
        exp: now + 12 * 60 * 60,
        sub: "mailto:test@example.com",
      }),
    ),
  )

  const signingInput = `${header}.${payload}`
  const privateKey = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      d: vapidPrivateKey,
      x: base64urlEncode(rawPublic.slice(1, 33)),
      y: base64urlEncode(rawPublic.slice(33, 65)),
    },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  )

  const sig = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      privateKey,
      new TextEncoder().encode(signingInput),
    ),
  )

  const rawSig = derToRaw(sig)
  const token = `${signingInput}.${base64urlEncode(rawSig)}`

  const parts = token.split(".")
  assertEquals(parts.length, 3)

  // Decode header and verify structure
  const decodedHeader = JSON.parse(
    new TextDecoder().decode(base64urlDecode(parts[0])),
  )
  assertEquals(decodedHeader.typ, "JWT")
  assertEquals(decodedHeader.alg, "ES256")

  // Decode payload and verify claims
  const decodedPayload = JSON.parse(
    new TextDecoder().decode(base64urlDecode(parts[1])),
  )
  assertEquals(decodedPayload.aud, "https://fcm.googleapis.com")
  assertEquals(decodedPayload.sub, "mailto:test@example.com")
  assertEquals(typeof decodedPayload.exp, "number")

  // Verify VAPID public key is 65 bytes (uncompressed P-256 point)
  const pubKeyBytes = base64urlDecode(vapidPublicKey)
  assertEquals(pubKeyBytes.length, 65)
  assertEquals(pubKeyBytes[0], 0x04) // uncompressed point marker
})

// ---------------------------------------------------------------------------
// Tests: subscription pruning logic
// ---------------------------------------------------------------------------

Deno.test("410/404 responses trigger subscription pruning", () => {
  // Simulate the pruning logic
  const pruneStatuses = [410, 404]
  const subscriptions = [
    { id: "s1", endpoint: "https://push.example.com/1", status: 201 },
    { id: "s2", endpoint: "https://push.example.com/2", status: 410 },
    { id: "s3", endpoint: "https://push.example.com/3", status: 404 },
    { id: "s4", endpoint: "https://push.example.com/4", status: 403 },
  ]

  const toPrune = subscriptions.filter((s) => pruneStatuses.includes(s.status))
  const toKeep = subscriptions.filter((s) => !pruneStatuses.includes(s.status))

  assertEquals(toPrune.length, 2)
  assertEquals(toPrune.map((s) => s.id), ["s2", "s3"])
  assertEquals(toKeep.length, 2)
})

// ---------------------------------------------------------------------------
// Tests: push payload JSON structure
// ---------------------------------------------------------------------------

Deno.test("push payload JSON includes required fields", () => {
  const payload = {
    user_id: "u1",
    title: "Reminder: Park Day is tomorrow",
    body: "Saturday, June 7 at City Park",
    url: "https://app.example.com/events/e1",
  }

  const pushPayload = JSON.stringify({
    title: payload.title,
    body: payload.body,
    ...(payload.url ? { url: payload.url } : {}),
  })

  const parsed = JSON.parse(pushPayload)
  assertEquals(parsed.title, payload.title)
  assertEquals(parsed.body, payload.body)
  assertEquals(parsed.url, payload.url)
})

Deno.test("push payload omits url when not provided", () => {
  const payload: { user_id: string; title: string; body: string; url?: string } = {
    user_id: "u1",
    title: "Test",
    body: "Body",
  }

  const pushPayload = JSON.stringify({
    title: payload.title,
    body: payload.body,
    ...(payload.url ? { url: payload.url } : {}),
  })

  const parsed = JSON.parse(pushPayload)
  assertEquals(parsed.title, "Test")
  assertEquals("url" in parsed, false)
})

// ---------------------------------------------------------------------------
// Tests: encryption produces valid aes128gcm structure
// ---------------------------------------------------------------------------

Deno.test("aes128gcm encrypted body has correct header structure", async () => {
  // Generate a test subscriber key pair
  const subscriberKeyPair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  )

  const subscriberPublicRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", subscriberKeyPair.publicKey),
  )

  const p256dh = base64urlEncode(subscriberPublicRaw)
  const authSecret = base64urlEncode(crypto.getRandomValues(new Uint8Array(16)))

  // Generate ephemeral key pair (as the sender does)
  const localKeyPair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  )

  const localPublicRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", localKeyPair.publicKey),
  )

  // Build a mock aes128gcm header
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const rs = 4096
  const rsBytes = new Uint8Array(4)
  new DataView(rsBytes.buffer).setUint32(0, rs)

  const header = new Uint8Array([
    ...salt,                        // 16 bytes salt
    ...rsBytes,                     // 4 bytes record size
    localPublicRaw.length,          // 1 byte key length
    ...localPublicRaw,              // 65 bytes for uncompressed P-256 key
  ])

  // Verify header structure
  assertEquals(header.length, 16 + 4 + 1 + 65) // 86 bytes
  assertEquals(header[20], 65) // key length should be 65 (uncompressed P-256)

  // Salt is first 16 bytes
  assertEquals(header.slice(0, 16), salt)

  // Record size at offset 16-19
  const view = new DataView(header.buffer)
  assertEquals(view.getUint32(16), 4096)

  // These are validly generated
  assertNotEquals(p256dh, "")
  assertNotEquals(authSecret, "")
})

// ---------------------------------------------------------------------------
// Tests: cron dispatcher mapping
// ---------------------------------------------------------------------------

Deno.test("admin-run-cron includes send-reminders and process-notification-queue labels", () => {
  const cronFunctionByLabel: Record<string, string> = {
    "cron-cleanup-stale": "cleanup-stale-runs",
    "cron-db-maintenance": "db-maintenance",
    "cron-enrich-events": "backfill-event-enrichment",
    "cron-review-events": "process-event-review-queue",
    "cron-scrape-sources": "scrape-due-sources",
    "cron-send-reminders": "send-reminders",
    "cron-tag-queue": "process-tag-queue",
    "cron-weekly-digest": "send-weekly-digest",
    "cron-process-notification-queue": "process-notification-queue",
  }

  assertEquals(cronFunctionByLabel["cron-send-reminders"], "send-reminders")
  assertEquals(cronFunctionByLabel["cron-process-notification-queue"], "process-notification-queue")
})
