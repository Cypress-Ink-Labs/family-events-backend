import "@supabase/functions-js/edge-runtime.d.ts";
import { serveAdminJson } from "../_shared/admin-handler.ts";
import { jsonResponse } from "../_shared/http.ts";
import { logEdgeEvent } from "../_shared/logger.ts";

const cronFunctionByLabel: Record<string, string> = {
  "cron-cleanup-stale": "cleanup-stale-runs",
  "cron-db-maintenance": "db-maintenance",
  "cron-enrich-events": "backfill-event-enrichment",
  "cron-review-events": "process-event-review-queue",
  "cron-scrape-sources": "scrape-due-sources",
  "cron-send-reminders": "send-reminders",
  "cron-tag-queue": "process-tag-queue",
  "cron-weekly-digest": "send-weekly-digest",
  "cron-process-notification-queue": "process-notification-queue",
};

function truncateBody(body: string): string {
  return body.replaceAll(/\r?\n/g, " ").slice(0, 2000);
}

serveAdminJson({ functionName: "admin-run-cron" }, async (
  { request, serviceRoleKey, supabase, supabaseUrl },
) => {
  const body = await request.json().catch(() => ({}));
  const label = typeof body?.label === "string" ? body.label : "";
  const functionName = cronFunctionByLabel[label];
  if (!functionName) {
    return jsonResponse({ error: "unknown cron label" }, { status: 400 });
  }

  const runKey = crypto.randomUUID();
  const startedAt = Date.now();
  const response = await fetch(
    `${supabaseUrl}/functions/v1/${functionName}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${serviceRoleKey}`,
        "X-Cron-Run-Key": runKey,
        "X-Cron-Label": label,
      },
      body: JSON.stringify({ cron_run_key: runKey, cron_label: label }),
    },
  );
  const durationSeconds = Math.max(
    0,
    Math.round((Date.now() - startedAt) / 1000),
  );
  const responseBody = truncateBody(await response.text());
  const status = response.ok ? "succeeded" : "failed";

  const { data: runId, error: logError } = await supabase.rpc(
    "log_railway_cron_run",
    {
      p_label: label,
      p_status: status,
      p_http_status: response.status,
      p_duration_s: durationSeconds,
      p_body: responseBody,
      p_run_key: runKey,
    },
  );
  if (logError) throw logError;

  logEdgeEvent(response.ok ? "log" : "error", "admin cron run completed", {
    function: "admin-run-cron",
    label,
    target_function: functionName,
    http_status: response.status,
    duration_s: durationSeconds,
  });

  if (!response.ok) {
    return jsonResponse(
      {
        error: "cron run failed",
        id: runId,
        run_key: runKey,
        label,
        http_status: response.status,
        body: responseBody,
      },
      { status: 502 },
    );
  }

  return jsonResponse({
    ok: true,
    id: runId,
    run_key: runKey,
    label,
    http_status: response.status,
    duration_s: durationSeconds,
    body: responseBody,
  });
});
