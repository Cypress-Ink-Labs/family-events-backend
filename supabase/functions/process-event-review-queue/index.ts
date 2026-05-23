import "@supabase/functions-js/edge-runtime.d.ts";
import { serveServiceRoleJson } from "../_shared/service-role-handler.ts";
import { buildReviewQueueDeps, processReviewQueueBatch } from "./lib/worker.ts";

if (import.meta.main) {
  serveServiceRoleJson(
    { functionName: "process-event-review-queue", errorStage: "outer" },
    async ({ supabase }) => {
      const summary = await processReviewQueueBatch(
        buildReviewQueueDeps(supabase),
      );

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
