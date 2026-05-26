import type { SupabaseClient } from "@supabase/supabase-js";
import type { cronRunContextFromRequest } from "../_shared/cron-run-log.ts";
import { logCronRunEvent } from "../_shared/cron-run-log.ts";
import { invokeFunction } from "../_shared/function-invoke.ts";
import { errorMessage } from "../_shared/logger.ts";

const PARENT_TIPS_BATCH = 8;

export interface ParentTipsPassSummary {
  enabled: boolean;
  claimed: number;
  generated: number;
  errors: number;
}

export interface ParentTipsPassDeps {
  cronContext: ReturnType<typeof cronRunContextFromRequest>;
  serviceRoleKey: string;
  supabase: SupabaseClient;
  supabaseUrl: string;
}

export async function runParentTipsPass(
  deps: ParentTipsPassDeps,
): Promise<ParentTipsPassSummary> {
  const summary: ParentTipsPassSummary = {
    enabled: false,
    claimed: 0,
    generated: 0,
    errors: 0,
  };

  const { data: cfg, error: cfgErr } = await deps.supabase
    .from("ai_feature_config")
    .select("enabled")
    .eq("feature", "parent-tips")
    .maybeSingle();

  if (cfgErr || !cfg || cfg.enabled !== true) {
    return summary;
  }
  summary.enabled = true;

  const { data: claims, error: claimErr } = await deps.supabase.rpc(
    "list_events_needing_parent_tips",
    { p_limit: PARENT_TIPS_BATCH },
  );
  if (claimErr) {
    await logCronRunEvent(
      deps.supabase,
      deps.cronContext,
      "warn",
      "parent-tips claim failed",
      {
        function: "backfill-event-enrichment",
        stage: "parent-tips",
        error: errorMessage(claimErr),
      },
    );
    return summary;
  }

  const rows = (claims ?? []) as Array<{ event_id: string }>;
  summary.claimed = rows.length;

  for (const row of rows) {
    try {
      const response = await invokeFunction(
        "generate-parent-tips",
        { event_id: row.event_id },
        {
          serviceRoleKey: deps.serviceRoleKey,
          supabaseUrl: deps.supabaseUrl,
          timeoutMs: 30_000,
          truncateBodyAt: 200,
        },
      );

      if (!response.ok) {
        if (response.status === 503) {
          summary.errors += 1;
          break;
        }
        summary.errors += 1;
        const { error: markErr } = await deps.supabase.rpc(
          "mark_event_enrichment_attempt",
          {
            p_event_id: row.event_id,
          },
        );
        if (markErr) {
          await logCronRunEvent(
            deps.supabase,
            deps.cronContext,
            "warn",
            "parent-tips mark attempt failed",
            {
              function: "backfill-event-enrichment",
              stage: "parent-tips",
              event_id: row.event_id,
              error: errorMessage(markErr),
            },
          );
        }
        continue;
      }

      summary.generated += 1;
    } catch (rowErr) {
      summary.errors += 1;
      await logCronRunEvent(
        deps.supabase,
        deps.cronContext,
        "warn",
        "parent-tips row failed",
        {
          function: "backfill-event-enrichment",
          stage: "parent-tips",
          event_id: row.event_id,
          error: errorMessage(rowErr),
        },
      );
    }
  }

  return summary;
}
