const secretNamePattern = /(TOKEN|KEY|SECRET|PASSWORD|AUTHORIZATION|ACCESS_TOKEN|SERVICE_ROLE)/i
const bearerPattern = /\bBearer\s+[A-Za-z0-9._~+/=-]+/g
const assignmentPattern =
  /\b([A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD|ACCESS_TOKEN|SERVICE_ROLE)[A-Z0-9_]*)=([^\s]+)/gi
const supabaseSecretPattern = /\bsb_secret_[A-Za-z0-9_-]+/g
const jwtPattern = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g

export function redact(value: string): string {
  return value
    .replace(bearerPattern, "Bearer [REDACTED]")
    .replace(assignmentPattern, "$1=[REDACTED]")
    .replace(supabaseSecretPattern, "[REDACTED_SUPABASE_SECRET]")
    .replace(jwtPattern, "[REDACTED_JWT]")
}

export function redactObject<T>(value: T): T {
  if (typeof value === "string") {
    return redact(value) as T
  }
  if (Array.isArray(value)) {
    return value.map((item) => redactObject(item)) as T
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        secretNamePattern.test(key) ? "[REDACTED]" : redactObject(item),
      ])
    ) as T
  }
  return value
}
