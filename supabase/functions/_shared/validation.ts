export type ReadStringOptions = { maxLength?: number; required?: boolean };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function readString(
  value: Record<string, unknown>,
  key: string,
  options: ReadStringOptions & { required: true },
): string;
export function readString(
  value: Record<string, unknown>,
  key: string,
  options?: ReadStringOptions,
): string | null;
export function readString(
  value: Record<string, unknown>,
  key: string,
  options: ReadStringOptions = {},
): string | null {
  const raw = value[key];
  if (raw == null) {
    if (options.required) throw new Error(`missing ${key}`);
    return null;
  }
  if (typeof raw !== "string") throw new Error(`invalid ${key}`);

  const trimmed = raw.trim();
  if (options.required && !trimmed) throw new Error(`missing ${key}`);
  if (options.maxLength !== undefined && trimmed.length > options.maxLength) {
    throw new Error(`invalid ${key}`);
  }

  return trimmed;
}

export function readEmail(
  value: Record<string, unknown>,
  key: string,
): string | null {
  const email = readString(value, key, { maxLength: 320 });
  if (email == null) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error(`invalid ${key}`);
  }
  return email.toLowerCase();
}

export function readUuid(
  value: Record<string, unknown>,
  key: string,
): string | null {
  const uuid = readString(value, key);
  if (uuid == null) return null;
  if (!UUID_PATTERN.test(uuid)) throw new Error(`invalid ${key}`);
  return uuid;
}
