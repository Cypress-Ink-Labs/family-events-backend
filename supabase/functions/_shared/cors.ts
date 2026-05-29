// Shared CORS origin allowlist for edge functions invoked from the browser.
// Promoted from scrape-source/index.ts so weather/ and other functions share a
// single source of truth instead of re-declaring the list.

export const DEFAULT_ALLOWED_ORIGINS = [
  "https://family-events.org",
  "https://www.family-events.org",
  "https://family-events.up.railway.app",
  "http://localhost:5173",
  "http://localhost:5174",
  "http://localhost:5175",
  "http://127.0.0.1:5173",
  "http://127.0.0.1:5174",
  "http://127.0.0.1:5175",
];

/**
 * Returns the request origin when it is on the allowlist, otherwise null.
 * The allowlist is overridable via the ALLOWED_ORIGINS env var (comma-separated).
 */
export function resolveAllowedOrigin(origin: string | null): string | null {
  const configured = Deno.env.get("ALLOWED_ORIGINS");
  const allowlist = (configured?.split(",") ?? DEFAULT_ALLOWED_ORIGINS)
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  if (!origin) return null;
  return allowlist.includes(origin) ? origin : null;
}

/**
 * Builds CORS headers for an allowlisted origin. When the origin is not
 * allowlisted (or absent, e.g. server-to-server callers), the
 * Access-Control-Allow-Origin header is omitted so browsers reject the
 * cross-origin response while same-origin / no-Origin callers still work.
 */
export function buildCorsHeaders(
  allowedOrigin: string | null,
  methods: string[] = ["POST", "OPTIONS"],
): Record<string, string> {
  const headers: Record<string, string> = {
    Vary: "Origin",
    "Access-Control-Allow-Methods": methods.join(", "),
    "Access-Control-Allow-Headers":
      "Content-Type, Authorization, X-Client-Info, Apikey",
  };
  if (allowedOrigin) {
    headers["Access-Control-Allow-Origin"] = allowedOrigin;
  }
  return headers;
}
