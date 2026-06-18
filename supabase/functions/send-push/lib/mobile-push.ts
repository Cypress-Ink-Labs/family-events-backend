export type PushPlatform = "web" | "ios" | "android";

export interface PushSubscriptionRow {
  id: string;
  platform: PushPlatform;
  token: string | null;
}

export interface MobilePushPayload {
  title: string;
  body: string;
  url?: string;
}

export interface ApnsCredentials {
  teamId: string;
  keyId: string;
  privateKey: string;
  bundleId: string;
  environment: "sandbox" | "production";
}

export interface FcmCredentials {
  projectId: string;
  clientEmail: string;
  privateKey: string;
}

export interface MobilePushCredentials {
  apns?: ApnsCredentials;
  fcm?: FcmCredentials;
}

export function partitionMobileSubscriptions(rows: PushSubscriptionRow[]): {
  apns: PushSubscriptionRow[];
  fcm: PushSubscriptionRow[];
} {
  const apns: PushSubscriptionRow[] = [];
  const fcm: PushSubscriptionRow[] = [];

  for (const row of rows) {
    if (!row.token) continue;
    if (row.platform === "ios") apns.push(row);
    if (row.platform === "android") fcm.push(row);
  }

  return { apns, fcm };
}

export function mobileCredentialStatus(credentials: MobilePushCredentials): {
  apns: boolean;
  fcm: boolean;
} {
  return {
    apns: Boolean(
      credentials.apns?.teamId &&
      credentials.apns.keyId &&
      credentials.apns.privateKey &&
      credentials.apns.bundleId,
    ),
    fcm: Boolean(
      credentials.fcm?.projectId && credentials.fcm.clientEmail && credentials.fcm.privateKey,
    ),
  };
}

export function buildApnsRequest(input: {
  token: string;
  jwt: string;
  bundleId: string;
  environment: "sandbox" | "production";
  payload: MobilePushPayload;
}): {
  url: string;
  headers: Record<string, string>;
  body: string;
} {
  const host =
    input.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";

  return {
    url: `https://${host}/3/device/${input.token}`,
    headers: {
      authorization: `bearer ${input.jwt}`,
      "apns-topic": input.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        alert: {
          title: input.payload.title,
          body: input.payload.body,
        },
        sound: "default",
      },
      ...(input.payload.url ? { url: input.payload.url } : {}),
    }),
  };
}

export function buildFcmMessage(input: {
  token: string;
  title: string;
  body: string;
  url?: string;
}): {
  message: {
    token: string;
    notification: { title: string; body: string };
    data: Record<string, string>;
    android: { priority: "HIGH"; notification: { channel_id: string } };
  };
} {
  return {
    message: {
      token: input.token,
      notification: {
        title: input.title,
        body: input.body,
      },
      data: input.url ? { url: input.url } : {},
      android: {
        priority: "HIGH",
        notification: { channel_id: "family_events" },
      },
    },
  };
}

export function base64urlEncode(data: Uint8Array): string {
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function pemToArrayBuffer(pem: string): ArrayBuffer {
  const normalized = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(normalized);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

export function derToRawSignature(signature: Uint8Array): Uint8Array {
  if (signature.length === 64) return signature;

  const raw = new Uint8Array(64);
  let offset = 2;
  offset++;
  const rLen = signature[offset++];
  const rStart = rLen > 32 ? offset + (rLen - 32) : offset;
  const rDest = rLen < 32 ? 32 - rLen : 0;
  raw.set(signature.slice(rStart, offset + rLen), rDest);
  offset += rLen;

  offset++;
  const sLen = signature[offset++];
  const sStart = sLen > 32 ? offset + (sLen - 32) : offset;
  const sDest = sLen < 32 ? 64 - sLen : 32;
  raw.set(signature.slice(sStart, offset + sLen), sDest);
  return raw;
}

export async function signApnsJwt(credentials: ApnsCredentials): Promise<string> {
  const header = base64urlEncode(
    new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: credentials.keyId })),
  );
  const payload = base64urlEncode(
    new TextEncoder().encode(
      JSON.stringify({
        iss: credentials.teamId,
        iat: Math.floor(Date.now() / 1000),
      }),
    ),
  );
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(credentials.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(signingInput),
    ),
  );
  return `${signingInput}.${base64urlEncode(derToRawSignature(signature))}`;
}

export function parseFcmServiceAccount(raw: string): FcmCredentials | undefined {
  if (!raw.trim()) return undefined;
  const parsed = JSON.parse(raw) as {
    project_id?: unknown;
    client_email?: unknown;
    private_key?: unknown;
  };
  if (
    typeof parsed.project_id !== "string" ||
    typeof parsed.client_email !== "string" ||
    typeof parsed.private_key !== "string"
  ) {
    return undefined;
  }
  return {
    projectId: parsed.project_id,
    clientEmail: parsed.client_email,
    privateKey: parsed.private_key,
  };
}

export async function getFcmAccessToken(credentials: FcmCredentials): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64urlEncode(
    new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })),
  );
  const payload = base64urlEncode(
    new TextEncoder().encode(
      JSON.stringify({
        iss: credentials.clientEmail,
        scope: "https://www.googleapis.com/auth/firebase.messaging",
        aud: "https://oauth2.googleapis.com/token",
        iat: now,
        exp: now + 3600,
      }),
    ),
  );
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(credentials.privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput)),
  );
  const assertion = `${signingInput}.${base64urlEncode(signature)}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) {
    throw new Error(`FCM OAuth token request failed: ${response.status}`);
  }
  const body = (await response.json()) as { access_token?: unknown };
  if (typeof body.access_token !== "string") {
    throw new Error("FCM OAuth token response missing access_token");
  }
  return body.access_token;
}
