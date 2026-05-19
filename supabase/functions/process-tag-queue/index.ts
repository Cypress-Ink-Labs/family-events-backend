import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "@supabase/supabase-js"
import { requireServiceRole } from "../_shared/auth.ts"
import { captureEdgeException } from "../_shared/sentry.ts"
import { errorContext, logEdgeEvent } from "../_shared/logger.ts"

// Retry policy (chosen in plan):
//   - exponential backoff (1, 2, 4, 8, 16 min) via next_attempt_at
//   - dead-letter after MAX_ATTEMPTS=5
//   - Sentry on dead-letter only (avoid noise from transient OpenAI 5xx)
const MAX_ATTEMPTS = 5
const BASE_BACKOFF_MS = 60_000
// Stay well under Supabase edge function 150s wall.
// qwen3:1.7b averages ~10s/event (cold-start higher), so 20 was hitting 504s.
const BATCH_SIZE = 8
const PER_ITEM_TIMEOUT_MS = 30_000

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
}

interface QueueRow {
  id: number
  event_id: string
  source_run_id: string | null
  trigger_type: "import" | "reclassify" | "manual-review"
  attempt_count: number
}

interface ProcessSummary {
  claimed: number
  succeeded: number
  failed: number
  dead: number
}

async function fetchEventInputs(
  supabase: SupabaseClient,
  eventId: string
): Promise<{ title: string; description: string } | null> {
  const { data, error } = await supabase
    .from("events")
    .select("title, description")
    .eq("id", eventId)
    .maybeSingle()
  if (error) throw error
  if (!data) return null
  return {
    title: String((data as { title?: unknown }).title ?? ""),
    description: String((data as { description?: unknown }).description ?? ""),
  }
}

async function callTagEvent(
  supabaseUrl: string,
  serviceRoleKey: string,
  row: QueueRow,
  inputs: { title: string; description: string }
): Promise<void> {
  const response = await fetch(`${supabaseUrl}/functions/v1/tag-event`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${serviceRoleKey}`,
    },
    body: JSON.stringify({
      event_id: row.event_id,
      source_run_id: row.source_run_id,
      trigger_type: row.trigger_type,
      title: inputs.title,
      description: inputs.description,
    }),
    signal: AbortSignal.timeout(PER_ITEM_TIMEOUT_MS),
  })

  if (!response.ok) {
    const body = await response.text().catch(() => "")
    throw new Error(`tag-event ${response.status}: ${body.slice(0, 200)}`)
  }
}

async function markSuccess(
  supabase: SupabaseClient,
  rowId: number
): Promise<void> {
  // 'failed' here means "no longer pending/processing"; the queue uses
  // 'failed' as a soft completion state and 'dead' as the terminal one.
  // Successful items also leave the active set — pick 'failed' as the
  // generic "done" status so the partial-unique index releases the event.
  // (We don't need a 'succeeded' enum: most observability cares about
  // pending depth + dead-letter count.)
  const { error } = await supabase
    .from("event_tag_queue")
    .update({
      status: "failed",
      finished_at: new Date().toISOString(),
      last_error: null,
    })
    .eq("id", rowId)
  if (error) throw error
}

async function markFailureOrDead(
  supabase: SupabaseClient,
  row: QueueRow,
  err: unknown
): Promise<{ dead: boolean }> {
  const errMsg = err instanceof Error ? err.message : String(err)
  const attempts = row.attempt_count // already incremented by claim_tag_queue_batch
  const isDead = attempts >= MAX_ATTEMPTS

  if (isDead) {
    const { error } = await supabase
      .from("event_tag_queue")
      .update({
        status: "dead",
        finished_at: new Date().toISOString(),
        last_error: errMsg.slice(0, 1000),
      })
      .eq("id", row.id)
    if (error) throw error
    return { dead: true }
  }

  // Exponential backoff. attempts=1 → 1 min, attempts=2 → 2 min, … attempts=4 → 8 min.
  const backoffMs = BASE_BACKOFF_MS * Math.pow(2, attempts - 1)
  const nextAttemptAt = new Date(Date.now() + backoffMs).toISOString()
  const { error } = await supabase
    .from("event_tag_queue")
    .update({
      status: "pending",
      started_at: null,
      next_attempt_at: nextAttemptAt,
      last_error: errMsg.slice(0, 1000),
    })
    .eq("id", row.id)
  if (error) throw error
  return { dead: false }
}

export async function processBatch(
  supabase: SupabaseClient,
  supabaseUrl: string,
  serviceRoleKey: string
): Promise<ProcessSummary> {
  const summary: ProcessSummary = { claimed: 0, succeeded: 0, failed: 0, dead: 0 }

  const { data: claimed, error: claimError } = await supabase.rpc("claim_tag_queue_batch", {
    p_limit: BATCH_SIZE,
  })
  if (claimError) throw claimError

  const rows = (claimed ?? []) as QueueRow[]
  summary.claimed = rows.length
  if (rows.length === 0) return summary

  for (const row of rows) {
    try {
      const inputs = await fetchEventInputs(supabase, row.event_id)
      if (!inputs || !inputs.title) {
        // Event was deleted between enqueue and claim, or has no title.
        // Don't retry — mark as a soft completion.
        await markSuccess(supabase, row.id)
        summary.succeeded += 1
        continue
      }

      await callTagEvent(supabaseUrl, serviceRoleKey, row, inputs)
      await markSuccess(supabase, row.id)
      summary.succeeded += 1
    } catch (err) {
      const { dead } = await markFailureOrDead(supabase, row, err).catch((markErr) => {
        // Updating the row itself failed — log loudly so we notice in Sentry.
        void captureEdgeException(
          markErr,
          errorContext(markErr, {
            function: "process-tag-queue",
            queue_row_id: row.id,
            event_id: row.event_id,
            stage: "mark-failure",
          })
        )
        return { dead: false }
      })

      if (dead) {
        summary.dead += 1
        await captureEdgeException(
          err,
          errorContext(err, {
            function: "process-tag-queue",
            queue_row_id: row.id,
            event_id: row.event_id,
            attempts: row.attempt_count,
            status: "dead",
          })
        )
        logEdgeEvent(
          "error",
          "tag-queue row dead-lettered",
          errorContext(err, {
            function: "process-tag-queue",
            queue_row_id: row.id,
            event_id: row.event_id,
            attempts: row.attempt_count,
          })
        )
      } else {
        summary.failed += 1
        // Transient failures intentionally NOT captured to Sentry to avoid
        // noise during OpenAI/edge outages. The queue_row itself preserves
        // last_error for inspection.
      }
    }
  }

  return summary
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders })
    }

    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""

    const auth = requireServiceRole(req, serviceRoleKey)
    if (!auth.ok) {
      return new Response(JSON.stringify({ error: auth.message }), {
        status: auth.status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    if (!supabaseUrl) {
      return new Response(JSON.stringify({ error: "SUPABASE_URL not configured" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    try {
      const supabase = createClient(supabaseUrl, serviceRoleKey)
      const summary = await processBatch(supabase, supabaseUrl, serviceRoleKey)
      logEdgeEvent("log", "process-tag-queue completed", {
        function: "process-tag-queue",
        ...summary,
      })
      return new Response(JSON.stringify(summary), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    } catch (err) {
      await captureEdgeException(
        err,
        errorContext(err, { function: "process-tag-queue", stage: "outer" })
      )
      logEdgeEvent(
        "error",
        "process-tag-queue outer failure",
        errorContext(err, { function: "process-tag-queue" })
      )
      return new Response(JSON.stringify({ error: String(err) }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }
  })
}
