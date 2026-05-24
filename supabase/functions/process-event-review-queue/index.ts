import "@supabase/functions-js/edge-runtime.d.ts";
import { cronRunContextFromRequest } from "../_shared/cron-run-log.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";
import { buildReviewQueueDeps, processReviewQueueBatch } from "./lib/worker.ts";

if (import.meta.main) {
  serveServiceRoleJson(
    { functionName: "process-event-review-queue", errorStage: "outer" },
    async ({ request, supabase }) => {
      const deps = await buildReviewQueueDeps(supabase);
      deps.cronContext = cronRunContextFromRequest(request);
      const summary = await processReviewQueueBatch(deps);

      return {
        processed: summary.succeeded + summary.retrying + summary.dead,
        approved: summary.approved,
        rejected: summary.rejected,
        needs_admin_review: summary.needsAdminReview,
        failed: summary.failed,
        retrying: summary.retrying,
        dead: summary.dead,
        claimed: summary.claimed,
        reaped: summary.reaped,
      };
    },
  );
}
