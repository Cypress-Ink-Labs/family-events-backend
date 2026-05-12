import { captureEdgeException } from "../../_shared/sentry.ts"
import { errorContext, logEdgeEvent } from "../../_shared/logger.ts"

const TAG_EVENT_MAX_ATTEMPTS = 3

async function invokeTagEvent(
  supabaseUrl: string,
  serviceRoleKey: string,
  body: Record<string, unknown>
): Promise<void> {
  for (let attempt = 1; attempt <= TAG_EVENT_MAX_ATTEMPTS; attempt++) {
    if (attempt > 1) {
      // Linear backoff: 500ms, 1000ms
      await new Promise((r) => setTimeout(r, 500 * (attempt - 1)))
    }

    const response = await fetch(`${supabaseUrl}/functions/v1/tag-event`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify(body),
    })

    if (response.ok) return

    // 5xx server errors and 429 rate limits are retriable; others are not
    const isRetriable =
      response.status === 429 ||
      response.status === 502 ||
      response.status === 503 ||
      response.status === 504
    if (!isRetriable || attempt === TAG_EVENT_MAX_ATTEMPTS) {
      throw new Error(`tag-event invocation failed (${response.status})`)
    }
  }
}

export async function tagImportedEvent(
  supabaseUrl: string,
  serviceRoleKey: string,
  eventId: string,
  title: string,
  description: string,
  sourceRunId?: string | null
) {
  try {
    await invokeTagEvent(supabaseUrl, serviceRoleKey, {
      event_id: eventId,
      source_run_id: sourceRunId ?? null,
      trigger_type: "import",
      title,
      description,
    })
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
