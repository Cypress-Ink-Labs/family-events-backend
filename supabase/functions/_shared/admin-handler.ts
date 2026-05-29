import type { SupabaseClient } from "@supabase/supabase-js";
import type { AuthResult } from "./auth.ts";
import { requireAdminOrService } from "./auth.ts";
import {
  buildCorsHeaders,
  type CorsOptions,
  errorJson,
  jsonResponse,
  optionsResponse,
} from "./http.ts";
import { errorContext } from "./logger.ts";
import { captureEdgeException } from "./sentry.ts";
import { createServiceClient } from "./supabase-client.ts";

export interface AdminJsonContext {
  anonKey: string;
  auth: Extract<AuthResult, { ok: true }>;
  request: Request;
  serviceRoleKey: string;
  supabase: SupabaseClient;
  supabaseUrl: string;
}

export interface AdminJsonOptions {
  cors?: CorsOptions;
  errorStage?: string;
  functionName: string;
  methods?: string[];
}

export type AdminJsonHandler = (
  context: AdminJsonContext,
) => Promise<Response | unknown>;

export class AdminJsonError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "AdminJsonError";
  }
}

export function adminJsonError(status: number, message: string) {
  return new AdminJsonError(status, message);
}

export interface AdminJsonDependencies {
  captureException?: typeof captureEdgeException;
  createServiceClient?: typeof createServiceClient;
  env?: Pick<typeof Deno.env, "get">;
  requireAdminOrService?: typeof requireAdminOrService;
}

export function createAdminJsonHandler(
  {
    cors,
    errorStage = "handler",
    functionName,
    methods = ["POST"],
  }: AdminJsonOptions,
  handler: AdminJsonHandler,
  deps: AdminJsonDependencies = {},
): (req: Request) => Promise<Response> {
  const corsHeaders = buildCorsHeaders({
    ...cors,
    methods: cors?.methods ?? [...methods, "OPTIONS"],
  });
  const env = deps.env ?? Deno.env;
  const serviceClientFactory = deps.createServiceClient ?? createServiceClient;
  const requireAuth = deps.requireAdminOrService ?? requireAdminOrService;
  const captureException = deps.captureException ?? captureEdgeException;

  return async (req: Request) => {
    if (req.method === "OPTIONS") return optionsResponse(corsHeaders);
    if (!methods.includes(req.method)) {
      return errorJson("method not allowed", 405, corsHeaders);
    }

    const supabaseUrl = env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const anonKey = env.get("SUPABASE_ANON_KEY") ?? "";

    if (!supabaseUrl) {
      return errorJson("SUPABASE_URL not configured", 500, corsHeaders);
    }
    if (!serviceRoleKey) {
      return errorJson(
        "SUPABASE_SERVICE_ROLE_KEY not configured",
        500,
        corsHeaders,
      );
    }
    if (!anonKey) {
      return errorJson("SUPABASE_ANON_KEY not configured", 500, corsHeaders);
    }

    const supabase = serviceClientFactory(supabaseUrl, serviceRoleKey);
    const auth = await requireAuth(
      req,
      supabase,
      supabaseUrl,
      serviceRoleKey,
      anonKey,
    );
    if (!auth.ok) return errorJson(auth.message, auth.status, corsHeaders);

    try {
      const result = await handler({
        anonKey,
        auth,
        request: req,
        serviceRoleKey,
        supabase,
        supabaseUrl,
      });
      if (result instanceof Response) {
        const headers = new Headers(result.headers);
        for (const [key, value] of Object.entries(corsHeaders)) {
          if (!headers.has(key)) headers.set(key, value);
        }
        return new Response(result.body, {
          status: result.status,
          statusText: result.statusText,
          headers,
        });
      }
      return jsonResponse(result, { headers: corsHeaders });
    } catch (err) {
      if (err instanceof AdminJsonError) {
        return errorJson(err.message, err.status, corsHeaders);
      }
      await captureException(
        err,
        errorContext(err, { function: functionName, stage: errorStage }),
      );
      // Do not leak DB/PostgREST detail (code=/details=) to callers. Full detail
      // is logged + sent to Sentry above.
      return errorJson("Internal error", 500, corsHeaders);
    }
  };
}

export function serveAdminJson(
  options: AdminJsonOptions,
  handler: AdminJsonHandler,
) {
  Deno.serve(createAdminJsonHandler(options, handler));
}
