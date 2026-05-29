import "@supabase/functions-js/edge-runtime.d.ts";
import { buildCorsHeaders, resolveAllowedOrigin } from "../_shared/cors.ts";
import { captureEdgeException } from "../_shared/sentry.ts";

// Server-side proxy for OpenWeather so the API key never ships in the client
// bundle. verify_jwt = true (config.toml) keeps this from being an open proxy:
// supabase-js attaches the anon/authenticated JWT on invoke.

const OPENWEATHER_ENDPOINT = "https://api.openweathermap.org/data/2.5/weather";
const UPSTREAM_TIMEOUT_MS = 5_000;

interface WeatherSnapshot {
  temperatureC: number | null;
  condition: string | null;
  observedAt: string | null;
}

function isValidLat(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= -90 &&
    value <= 90;
}

function isValidLon(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= -180 &&
    value <= 180;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  const allowedOrigin = resolveAllowedOrigin(origin);
  const corsHeaders = buildCorsHeaders(allowedOrigin, ["POST", "OPTIONS"]);
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  if (origin && !allowedOrigin) {
    return new Response(JSON.stringify({ error: "origin not allowed" }), {
      status: 403,
      headers: jsonHeaders,
    });
  }

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const apiKey = Deno.env.get("OPENWEATHER_API_KEY");
  if (!apiKey) {
    return new Response(JSON.stringify({ error: "weather unavailable" }), {
      status: 503,
      headers: jsonHeaders,
    });
  }

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    body = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {};
  } catch {
    body = {};
  }

  const lat = body.lat ?? body.latitude;
  const lon = body.lon ?? body.longitude;
  if (!isValidLat(lat) || !isValidLon(lon)) {
    return new Response(JSON.stringify({ error: "invalid coordinates" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  const upstream = new URL(OPENWEATHER_ENDPOINT);
  upstream.searchParams.set("lat", String(lat));
  upstream.searchParams.set("lon", String(lon));
  upstream.searchParams.set("appid", apiKey);
  upstream.searchParams.set("units", "metric");

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
    let response: Response;
    try {
      response = await fetch(upstream, {
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }

    if (!response.ok) {
      // Map upstream auth/rate errors to a generic status without leaking the
      // upstream body or the API key.
      const status = response.status === 429 || response.status >= 500
        ? 502
        : 503;
      return new Response(JSON.stringify({ error: "weather unavailable" }), {
        status,
        headers: jsonHeaders,
      });
    }

    const payload = await response.json();
    const snapshot: WeatherSnapshot = {
      condition: typeof payload?.weather?.[0]?.main === "string"
        ? payload.weather[0].main
        : null,
      temperatureC: typeof payload?.main?.temp === "number"
        ? payload.main.temp
        : null,
      observedAt: typeof payload?.dt === "number"
        ? new Date(payload.dt * 1000).toISOString()
        : null,
    };

    return new Response(JSON.stringify(snapshot), {
      status: 200,
      headers: jsonHeaders,
    });
  } catch (error) {
    await captureEdgeException(error, { scope: "weather" });
    return new Response(JSON.stringify({ error: "weather unavailable" }), {
      status: 502,
      headers: jsonHeaders,
    });
  }
});
