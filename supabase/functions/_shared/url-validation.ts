// Pure URL validation helpers for SSRF hardening. No Deno imports — safe to
// import from Vitest (Node) tests, the edge function (Deno runtime), and the
// browser bundle (Vite).
//
// Rejects non-http(s) schemes and IP literals in private / loopback / link-local
// / unique-local ranges. Hostnames that resolve to these ranges via DNS are NOT
// covered here — that is a separate DNS-rebinding concern.

export interface UrlValidationResult {
  ok: boolean
  reason?: string
}

const BLOCKED_PROTOCOLS_MSG = "Only http and https URLs are allowed"

export function validateExternalUrl(input: unknown): UrlValidationResult {
  if (typeof input !== "string" || input.length === 0) {
    return { ok: false, reason: "URL is required" }
  }

  let url: URL
  try {
    url = new URL(input)
  } catch {
    return { ok: false, reason: "Invalid URL" }
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return { ok: false, reason: BLOCKED_PROTOCOLS_MSG }
  }

  const hostname = url.hostname
  if (!hostname) {
    return { ok: false, reason: "URL is missing a hostname" }
  }

  const ipv4 = parseIPv4(hostname)
  if (ipv4) {
    const blocked = blockedIPv4Reason(ipv4)
    if (blocked) {
      return { ok: false, reason: blocked }
    }
    return { ok: true }
  }

  const ipv6Host = stripIpv6Brackets(hostname)
  const ipv6 = parseIPv6(ipv6Host)
  if (ipv6) {
    const blocked = blockedIPv6Reason(ipv6)
    if (blocked) {
      return { ok: false, reason: blocked }
    }
    return { ok: true }
  }

  return { ok: true }
}

function parseIPv4(host: string): [number, number, number, number] | null {
  const match = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
  if (!match) return null
  const octets: [number, number, number, number] = [
    Number(match[1]),
    Number(match[2]),
    Number(match[3]),
    Number(match[4]),
  ]
  for (const o of octets) {
    if (!Number.isInteger(o) || o < 0 || o > 255) return null
  }
  return octets
}

function blockedIPv4Reason(octets: [number, number, number, number]): string | null {
  const [a, b] = octets
  if (a === 127) return "Blocked IPv4 range 127.0.0.0/8 (loopback)"
  if (a === 10) return "Blocked IPv4 range 10.0.0.0/8 (private)"
  if (a === 172 && b >= 16 && b <= 31) return "Blocked IPv4 range 172.16.0.0/12 (private)"
  if (a === 192 && b === 168) return "Blocked IPv4 range 192.168.0.0/16 (private)"
  if (a === 169 && b === 254) return "Blocked IPv4 range 169.254.0.0/16 (link-local/metadata)"
  return null
}

function stripIpv6Brackets(host: string): string {
  if (host.startsWith("[") && host.endsWith("]")) return host.slice(1, -1)
  return host
}

function parseIPv6(host: string): number[] | null {
  if (!host.includes(":")) return null
  if (!/^[0-9a-fA-F:]+$/.test(host)) return null

  const parts = host.split("::")
  if (parts.length > 2) return null

  const leftRaw = parts[0]
  const rightRaw = parts.length === 2 ? parts[1] : ""
  const left = leftRaw.length > 0 ? leftRaw.split(":") : []
  const right = rightRaw.length > 0 ? rightRaw.split(":") : []

  if (parts.length === 1) {
    if (left.length !== 8) return null
    return toGroups(left)
  }

  const missing = 8 - left.length - right.length
  if (missing < 1) return null
  const all = [...left, ...Array(missing).fill("0"), ...right]
  return toGroups(all)
}

function toGroups(parts: string[]): number[] | null {
  const out: number[] = []
  for (const p of parts) {
    if (p.length === 0 || p.length > 4) return null
    if (!/^[0-9a-fA-F]+$/.test(p)) return null
    out.push(parseInt(p, 16))
  }
  return out.length === 8 ? out : null
}

function blockedIPv6Reason(groups: number[]): string | null {
  // ::1 loopback
  if (groups.slice(0, 7).every((g) => g === 0) && groups[7] === 1) {
    return "Blocked IPv6 address ::1 (loopback)"
  }
  const first = groups[0]
  const firstByte = first >> 8
  // fc00::/7 — first 7 bits = 1111110x, i.e. first byte 0xfc or 0xfd (ULA)
  if (firstByte === 0xfc || firstByte === 0xfd) {
    if (firstByte === 0xfd) return "Blocked IPv6 range fd00::/8 (unique-local)"
    return "Blocked IPv6 range fc00::/7 (unique-local)"
  }
  // fe80::/10 — first 10 bits = 1111111010
  if ((first & 0xffc0) === 0xfe80) {
    return "Blocked IPv6 range fe80::/10 (link-local)"
  }
  return null
}
