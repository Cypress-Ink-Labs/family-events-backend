export async function tagImportedEvent(
  supabaseUrl: string,
  serviceRoleKey: string,
  eventId: string,
  title: string,
  description: string,
  sourceRunId?: string | null
) {
  try {
    await fetch(`${supabaseUrl}/functions/v1/tag-event`, {
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
  } catch (err) {
    console.error("tag-event invocation failed", { eventId, err: String(err) })
  }
}
