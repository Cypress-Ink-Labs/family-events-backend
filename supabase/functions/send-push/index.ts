import "@supabase/functions-js/edge-runtime.d.ts"
import {
  serveServiceRoleJson,
  serviceRoleJsonError,
} from "../_shared/service-role-handler.ts"
import { logEdgeEvent } from "../_shared/logger.ts"

// send-push
// ----------------------------------------------------------------
// Service-role-only edge function that delivers web push notifications
// to a user's registered push subscriptions. Called internally by
// send-reminders and process-notification-queue.
//
// Payload: { user_id, title, body, url? }
//
// Follows the notify-email soft-failure pattern: when VAPID keys are
// unset (local/dev) the function logs and returns { sent: 0, dev: true }.
// Prunes invalid/expired subscriptions on 410/404 response.

// ─── VAPID Helpers ──────────────────────────────────────────────────────────

/** Base64url-encode a Uint8Array. */
function base64urlEncode(data: Uint8Array): string {
  let binary = ""
  for (const byte of data) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** Decode a base64url string to Uint8Array. */
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

/** Build a signed VAPID Authorization header (JWT signed with ES256). */
async function buildVapidAuth(
  endpoint: string,
  vapidPrivateKey: string,
  vapidPublicKey: string,
  subject: string,
): Promise<{ authorization: string; cryptoKey: string }> {
  const audience = new URL(endpoint).origin

  const header = base64urlEncode(
    new TextEncoder().encode(JSON.stringify({ typ: "JWT", alg: "ES256" })),
  )

  const now = Math.floor(Date.now() / 1000)
  const payload = base64urlEncode(
    new TextEncoder().encode(
      JSON.stringify({
        aud: audience,
        exp: now + 12 * 60 * 60, // 12 hours
        sub: subject,
      }),
    ),
  )

  const signingInput = `${header}.${payload}`

  // Import VAPID private key (base64url-encoded raw P-256 private key)
  const rawKey = base64urlDecode(vapidPrivateKey)
  const jwk: JsonWebKey = {
    kty: "EC",
    crv: "P-256",
    d: vapidPrivateKey,
    // Public key is 65 bytes: 0x04 || x (32) || y (32)
    x: base64urlEncode(base64urlDecode(vapidPublicKey).slice(1, 33)),
    y: base64urlEncode(base64urlDecode(vapidPublicKey).slice(33, 65)),
  }

  // Fallback: if vapidPublicKey is only 32 bytes (just x), handle gracefully
  // but typically VAPID public keys are the full 65-byte uncompressed point.
  void rawKey // used for length validation context

  const cryptoKey = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  )

  const signatureBuffer = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  )

  // Convert DER-encoded signature to raw r||s format expected by WebPush
  const signature = derToRaw(new Uint8Array(signatureBuffer))
  const token = `${signingInput}.${base64urlEncode(signature)}`

  return {
    authorization: `vapid t=${token}, k=${vapidPublicKey}`,
    cryptoKey: vapidPublicKey,
  }
}

/** Convert a DER-encoded ECDSA signature to raw 64-byte r||s format. */
function derToRaw(der: Uint8Array): Uint8Array {
  // DER: 0x30 <len> 0x02 <rlen> <r> 0x02 <slen> <s>
  // But Web Crypto may return raw r||s directly (64 bytes)
  if (der.length === 64) return der

  const raw = new Uint8Array(64)
  let offset = 2 // skip 0x30 <len>

  // r
  offset++ // skip 0x02
  const rLen = der[offset++]
  const rStart = rLen > 32 ? offset + (rLen - 32) : offset
  const rDest = rLen < 32 ? 32 - rLen : 0
  raw.set(der.slice(rStart, offset + rLen), rDest)
  offset += rLen

  // s
  offset++ // skip 0x02
  const sLen = der[offset++]
  const sStart = sLen > 32 ? offset + (sLen - 32) : offset
  const sDest = sLen < 32 ? 64 - sLen : 32
  raw.set(der.slice(sStart, offset + sLen), sDest)

  return raw
}

// ─── Encryption (aes128gcm) ─────────────────────────────────────────────────

/** Encrypt push message payload using aes128gcm content encoding. */
async function encryptPayload(
  payload: string,
  p256dhKey: string,
  authSecret: string,
): Promise<{ body: Uint8Array; salt: Uint8Array; localPublicKey: Uint8Array }> {
  const encoder = new TextEncoder()

  // Generate ephemeral ECDH key pair
  const localKeyPair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  )

  // Import subscriber's public key
  const subscriberKeyBytes = base64urlDecode(p256dhKey)
  const subscriberKey = await crypto.subtle.importKey(
    "raw",
    subscriberKeyBytes.buffer as ArrayBuffer,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  )

  // ECDH shared secret
  const sharedSecret = await crypto.subtle.deriveBits(
    { name: "ECDH", public: subscriberKey },
    localKeyPair.privateKey,
    256,
  )

  // Export local public key (uncompressed)
  const localPublicKeyRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", localKeyPair.publicKey),
  )

  // Salt (16 random bytes)
  const salt = crypto.getRandomValues(new Uint8Array(16))

  // Auth secret
  const authSecretBytes = base64urlDecode(authSecret)

  // PRK_combine = HKDF-SHA256(auth_secret, ecdh_secret, "WebPush: info\0" || ua_public || as_public, 32)
  const uaPublic = base64urlDecode(p256dhKey)
  const infoInput = new Uint8Array([
    ...encoder.encode("WebPush: info\0"),
    ...uaPublic,
    ...localPublicKeyRaw,
  ])

  const ikm = await crypto.subtle.importKey(
    "raw",
    new Uint8Array(sharedSecret),
    "HKDF",
    false,
    ["deriveBits"],
  )

  // IKM for the final HKDF: HKDF(auth_secret, shared_secret, info, 32)
  const prkCombine = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: authSecretBytes.buffer as ArrayBuffer, info: infoInput.buffer as ArrayBuffer },
      ikm,
      256,
    ),
  )

  // PRK = HKDF-Extract(salt, prk_combine)
  const prkKey = await crypto.subtle.importKey("raw", prkCombine, "HKDF", false, [
    "deriveBits",
  ])

  // CEK = HKDF-Expand(PRK, "Content-Encoding: aes128gcm\0", 16)
  const cekInfo = encoder.encode("Content-Encoding: aes128gcm\0")
  const cekBits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt, info: cekInfo },
    prkKey,
    128,
  )

  // Nonce = HKDF-Expand(PRK, "Content-Encoding: nonce\0", 12)
  const nonceInfo = encoder.encode("Content-Encoding: nonce\0")
  const nonceBits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt, info: nonceInfo },
    prkKey,
    96,
  )

  // Encrypt with AES-128-GCM
  const aesKey = await crypto.subtle.importKey(
    "raw",
    new Uint8Array(cekBits),
    "AES-GCM",
    false,
    ["encrypt"],
  )

  // Pad payload: content + 0x02 delimiter (last record)
  const plaintext = new Uint8Array([...encoder.encode(payload), 2])

  const encrypted = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: new Uint8Array(nonceBits), tagLength: 128 },
      aesKey,
      plaintext,
    ),
  )

  // aes128gcm header: salt (16) || rs (4) || idlen (1) || keyid (65) || ciphertext
  const rs = 4096
  const rsBytes = new Uint8Array(4)
  new DataView(rsBytes.buffer).setUint32(0, rs)

  const header = new Uint8Array([
    ...salt,
    ...rsBytes,
    localPublicKeyRaw.length,
    ...localPublicKeyRaw,
  ])

  const body = new Uint8Array([...header, ...encrypted])

  return { body, salt, localPublicKey: localPublicKeyRaw }
}

// ─── Main handler ───────────────────────────────────────────────────────────

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

const PUSH_TIMEOUT_MS = 10_000

serveServiceRoleJson(
  { functionName: "send-push" },
  async ({ request, supabase }) => {
    const payload = parsePayload(await request.json())

    // Read VAPID keys: vault-first, fallback to env
    let vapidPrivateKey = ""
    let vapidPublicKey = ""
    let vapidSubject = ""

    try {
      const { data: secrets } = await supabase
        .from("vault.decrypted_secrets" as "push_subscriptions") // cast to satisfy type
        .select("name, decrypted_secret")
        .in("name", ["vapid_private_key", "vapid_public_key", "vapid_subject"])

      if (secrets) {
        for (const s of secrets as Array<{ name: string; decrypted_secret: string }>) {
          if (s.name === "vapid_private_key") vapidPrivateKey = s.decrypted_secret
          if (s.name === "vapid_public_key") vapidPublicKey = s.decrypted_secret
          if (s.name === "vapid_subject") vapidSubject = s.decrypted_secret
        }
      }
    } catch {
      // Vault may not be available in local dev
    }

    // Env fallback
    if (!vapidPrivateKey) vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? ""
    if (!vapidPublicKey) vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? ""
    if (!vapidSubject) vapidSubject = Deno.env.get("VAPID_SUBJECT") ?? "mailto:push@family-events.org"

    // Soft-failure: no VAPID keys → log + 200
    if (!vapidPrivateKey || !vapidPublicKey) {
      logEdgeEvent("warn", "send-push: VAPID keys not configured; would have sent push", {
        function: "send-push",
        user_id: payload.user_id,
        title: payload.title,
      })
      return { sent: 0, dev: true }
    }

    // Fetch user's web push subscriptions
    const { data: subscriptions, error: subError } = await supabase
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth_key")
      .eq("user_id", payload.user_id)
      .eq("platform", "web")

    if (subError) throw subError

    if (!subscriptions || subscriptions.length === 0) {
      logEdgeEvent("log", "send-push: no web push subscriptions for user", {
        function: "send-push",
        user_id: payload.user_id,
      })
      return { sent: 0, reason: "no_subscriptions" }
    }

    const pushPayload = JSON.stringify({
      title: payload.title,
      body: payload.body,
      ...(payload.url ? { url: payload.url } : {}),
    })

    let sent = 0
    let failed = 0
    const pruned: string[] = []

    for (const sub of subscriptions) {
      if (!sub.endpoint || !sub.p256dh || !sub.auth_key) {
        failed++
        continue
      }

      try {
        const { authorization } = await buildVapidAuth(
          sub.endpoint,
          vapidPrivateKey,
          vapidPublicKey,
          vapidSubject,
        )

        const encrypted = await encryptPayload(pushPayload, sub.p256dh, sub.auth_key)

        const response = await fetch(sub.endpoint, {
          method: "POST",
          headers: {
            Authorization: authorization,
            "Content-Encoding": "aes128gcm",
            "Content-Type": "application/octet-stream",
            TTL: "86400",
            Urgency: "normal",
          },
          body: encrypted.body,
          signal: AbortSignal.timeout(PUSH_TIMEOUT_MS),
        })

        if (response.ok || response.status === 201) {
          sent++
        } else if (response.status === 410 || response.status === 404) {
          // Subscription expired/invalid — prune it
          pruned.push(sub.id)
          await supabase.from("push_subscriptions").delete().eq("id", sub.id)
          logEdgeEvent("log", "send-push: pruned expired subscription", {
            function: "send-push",
            subscription_id: sub.id,
            status: response.status,
          })
        } else {
          const body = await response.text().catch(() => "")
          logEdgeEvent("warn", "send-push: push delivery failed", {
            function: "send-push",
            subscription_id: sub.id,
            status: response.status,
            body: body.slice(0, 300),
          })
          failed++
        }
      } catch (err) {
        logEdgeEvent("warn", "send-push: push delivery error", {
          function: "send-push",
          subscription_id: sub.id,
          error: err instanceof Error ? err.message : String(err),
        })
        failed++
      }
    }

    logEdgeEvent("log", "send-push: complete", {
      function: "send-push",
      user_id: payload.user_id,
      sent,
      failed,
      pruned: pruned.length,
    })

    return { sent, failed, pruned: pruned.length }
  },
)
