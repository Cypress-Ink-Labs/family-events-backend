type EnvReader = Pick<typeof Deno.env, "get">;

export function optionalEnv(
  name: string,
  env: EnvReader = Deno.env,
): string {
  return (env.get(name) ?? "").trim();
}

export function requiredEnv(
  name: string,
  env: EnvReader = Deno.env,
): string {
  const value = optionalEnv(name, env);
  if (!value) {
    throw new Error(`${name} not configured`);
  }
  return value;
}

export function intEnv(
  name: string,
  fallback: number,
  env: EnvReader = Deno.env,
): number {
  const raw = optionalEnv(name, env);
  if (!raw) return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.trunc(parsed);
}

export function boolEnv(
  name: string,
  fallback: boolean,
  env: EnvReader = Deno.env,
): boolean {
  const normalized = optionalEnv(name, env).toLowerCase();
  if (normalized === "true") return true;
  if (normalized === "false") return false;
  return fallback;
}

export function urlEnv(
  name: string,
  fallback = "",
  env: EnvReader = Deno.env,
): string {
  const value = optionalEnv(name, env);
  return value || fallback;
}
