import type { SupabaseClient } from "@supabase/supabase-js";
import { type EdgeLogLevel, logEdgeEvent } from "./logger.ts";

export interface CronRunContext {
  runKey: string | null;
  label: string | null;
}

const RUN_KEY_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export function cronRunContextFromRequest(req: Request): CronRunContext {
  const headerRunKey = req.headers.get("x-cron-run-key");
  const headerLabel = req.headers.get("x-cron-label");

  return {
    runKey: headerRunKey && RUN_KEY_RE.test(headerRunKey) ? headerRunKey : null,
    label: headerLabel ? headerLabel.slice(0, 120) : null,
  };
}

export async function logCronRunEvent(
  supabase: SupabaseClient,
  context: CronRunContext,
  level: EdgeLogLevel,
  message: string,
  metadata: Record<string, unknown> = {},
) {
  logEdgeEvent(level, message, metadata);

  if (!context.runKey || !context.label) return;

  const { error } = await supabase.rpc("log_cron_run_event", {
    p_run_key: context.runKey,
    p_label: context.label,
    p_provider: "supabase",
    p_level: level,
    p_message: message,
    p_metadata: metadata,
  });

  if (error) {
    logEdgeEvent("warn", "cron run log persist failed", {
      message: error.message,
      code: error.code ?? null,
    });
  }
}
