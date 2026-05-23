import "@supabase/functions-js/edge-runtime.d.ts";
import {
  serveServiceRoleJson,
  serviceRoleJsonError,
} from "../_shared/service-role-handler.ts";

serveServiceRoleJson(
  { functionName: "log-cron-run" },
  async ({ request, supabase }) => {
    const { label, status, http_status, duration_s, body } = await request
      .json();

    if (!label || !status) {
      throw serviceRoleJsonError(400, "label and status are required");
    }

    const { error } = await supabase.rpc("log_railway_cron_run", {
      p_label: String(label),
      p_status: String(status),
      p_http_status: http_status ?? null,
      p_duration_s: duration_s ?? null,
      p_body: body ? String(body) : null,
    });
    if (error) throw error;

    return { ok: true };
  },
);
