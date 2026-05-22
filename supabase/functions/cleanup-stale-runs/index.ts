import "@supabase/functions-js/edge-runtime.d.ts";
import { logEdgeEvent } from "../_shared/logger.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";

serveServiceRoleJson(
  { functionName: "cleanup-stale-runs", errorStage: "rpc" },
  async ({
    supabase,
  }) => {
    const { error } = await supabase.rpc("run_cleanup_stale_runs");
    if (error) throw error;
    logEdgeEvent("log", "cleanup-stale-runs completed", {
      function: "cleanup-stale-runs",
    });
    return { ok: true };
  },
);
