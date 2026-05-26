export interface CorsOptions {
  allowHeaders?: string[];
  methods?: string[];
  origin?: string;
}

const DEFAULT_ALLOW_HEADERS = [
  "Content-Type",
  "Authorization",
  "X-Client-Info",
  "Apikey",
];

export function buildCorsHeaders(
  options: CorsOptions = {},
): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": options.origin ?? "*",
    "Access-Control-Allow-Methods": (options.methods ?? ["POST", "OPTIONS"])
      .join(", "),
    "Access-Control-Allow-Headers":
      (options.allowHeaders ?? DEFAULT_ALLOW_HEADERS).join(", "),
  };
}

function mergeHeaders(base: HeadersInit, override?: HeadersInit): Headers {
  const headers = new Headers(base);
  if (override) {
    new Headers(override).forEach((value, key) => headers.set(key, value));
  }
  return headers;
}

export function jsonResponse(
  body: unknown,
  init: { status?: number; headers?: HeadersInit } = {},
): Response {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: mergeHeaders({ "Content-Type": "application/json" }, init.headers),
  });
}

export function errorJson(
  error: string,
  status: number,
  headers?: HeadersInit,
): Response {
  return jsonResponse({ error }, { status, headers });
}

export function optionsResponse(headers: HeadersInit): Response {
  return new Response(null, { status: 200, headers });
}

export function methodNotAllowed(headers: HeadersInit): Response {
  return errorJson("method not allowed", 405, headers);
}

export async function parseJsonObject(
  req: Request,
): Promise<Record<string, unknown>> {
  try {
    const body = await req.json();
    return body !== null && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}
