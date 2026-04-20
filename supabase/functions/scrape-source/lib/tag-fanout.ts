import { captureEdgeException } from "../../_shared/sentry.ts"
import { errorContext, logEdgeEvent } from "../../_shared/logger.ts"

export async function tagImportedEvent(
  supabaseUrl: string,
  serviceRoleKey: string,
  eventId: string,
  title: string,
  description: string,
  sourceRunId?: string | null
) {
  try {
    const response = await fetch(`${supabaseUrl}/functions/v1/tag-event`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({
        event_id: eventId,
        source_run_id: sourceRunId ?? null,
        trigger_type: "import",
        title,
        description,
      }),
    })

    if (!response.ok) {
      throw new Error(`tag-event invocation failed (${response.status})`)
    }
  } catch (err) {
    await captureEdgeException(
      err,
      errorContext(err, {
        function: "scrape-source",
        downstream_function: "tag-event",
        event_id: eventId,
        source_run_id: sourceRunId ?? null,
      })
    )
    logEdgeEvent(
      "error",
      "tag-event invocation failed",
      errorContext(err, {
        function: "scrape-source",
        downstream_function: "tag-event",
        event_id: eventId,
        source_run_id: sourceRunId ?? null,
      })
    )
  }
}
