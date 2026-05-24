import "@supabase/functions-js/edge-runtime.d.ts";
import {
  serveServiceRoleJson,
  serviceRoleJsonError,
} from "../_shared/service-role-handler.ts";

serveServiceRoleJson(
  { functionName: "log-cron-run" },
  async ({ request, supabase }) => {
    const {
      run_key,
      label,
      status,
      http_status,
      duration_s,
      body,
      runner_log,
    } = await request.json();

    if (!label || !status) {
      throw serviceRoleJsonError(400, "label and status are required");
    }

    const { error } = await supabase.rpc("log_railway_cron_run", {
      p_label: String(label),
      p_status: String(status),
      p_http_status: http_status ?? null,
      p_duration_s: duration_s ?? null,
      p_body: body ? String(body) : null,
      p_run_key: run_key ? String(run_key) : undefined,
      p_runner_log: runner_log ? String(runner_log) : null,
    });
    if (error) throw error;

    return { ok: true };
  },
);
