import "@supabase/functions-js/edge-runtime.d.ts";
import {
  cronRunContextFromRequest,
  logCronRunEvent,
} from "../_shared/cron-run-log.ts";
import { errorContext } from "../_shared/logger.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";
import { kickProcessSourceQueue } from "../scrape-source/lib/source-queue.ts";

declare const EdgeRuntime:
  | { waitUntil<T>(promise: Promise<T>): Promise<T> }
  | undefined;

export function normalizeDueScrapePayload(
  value: unknown,
): { enqueued: number } {
  if (value && typeof value === "object" && "enqueued" in value) {
    return { enqueued: Number((value as { enqueued: unknown }).enqueued ?? 0) };
  }
  return { enqueued: 0 };
}

serveServiceRoleJson(
  { errorStage: "rpc", functionName: "scrape-due-sources" },
  async ({ request, serviceRoleKey, supabase, supabaseUrl }) => {
    const cronContext = cronRunContextFromRequest(request);

    try {
      const { data, error } = await supabase.rpc("run_due_source_scrapes");
      if (error) throw error;

      const kick = kickProcessSourceQueue(supabaseUrl, serviceRoleKey).catch(
        async (kickError) => {
          await logCronRunEvent(
            supabase,
            cronContext,
            "warn",
            "source-queue safety kick failed",
            errorContext(kickError, {
              function: "scrape-due-sources",
              stage: "kick-source",
            }),
          );
        },
      );
      if (typeof EdgeRuntime !== "undefined") {
        EdgeRuntime.waitUntil(kick);
      } else {
        await kick;
      }

      await logCronRunEvent(
        supabase,
        cronContext,
        "log",
        "scrape-due-sources dispatched",
        { function: "scrape-due-sources" },
      );

      return normalizeDueScrapePayload(data);
    } catch (err) {
      await logCronRunEvent(
        supabase,
        cronContext,
        "error",
        "scrape-due-sources failed",
        errorContext(err, { function: "scrape-due-sources", stage: "rpc" }),
      );
      throw err;
    }
  },
);
