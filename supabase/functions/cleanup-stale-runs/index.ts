import "@supabase/functions-js/edge-runtime.d.ts";
import {
  cronRunContextFromRequest,
  logCronRunEvent,
} from "../_shared/cron-run-log.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";

serveServiceRoleJson(
  { functionName: "cleanup-stale-runs", errorStage: "rpc" },
  async ({
    request,
    supabase,
  }) => {
    const cronContext = cronRunContextFromRequest(request);
    const { error } = await supabase.rpc("run_cleanup_stale_runs");
    if (error) throw error;
    await logCronRunEvent(
      supabase,
      cronContext,
      "log",
      "cleanup-stale-runs completed",
      {
        function: "cleanup-stale-runs",
      },
    );
    return { ok: true };
  },
);
