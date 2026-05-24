import "@supabase/functions-js/edge-runtime.d.ts";
import {
  cronRunContextFromRequest,
  logCronRunEvent,
} from "../_shared/cron-run-log.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";

serveServiceRoleJson(
  { functionName: "db-maintenance", errorStage: "rpc" },
  async ({
    request,
    supabase,
  }) => {
    const cronContext = cronRunContextFromRequest(request);
    const { data, error } = await supabase.rpc("run_daily_maintenance");
    if (error) throw error;
    await logCronRunEvent(
      supabase,
      cronContext,
      "log",
      "db-maintenance completed",
      {
        function: "db-maintenance",
        ...((data ?? {}) as Record<string, unknown>),
      },
    );
    return { ok: true, results: data };
  },
);
