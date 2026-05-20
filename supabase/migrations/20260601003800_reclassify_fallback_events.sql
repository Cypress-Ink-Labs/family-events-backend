-- One-off bulk re-tag pass for events that previously went through the
-- keyword-fallback path (or were never tagged at all).
--
-- Context: migration 20260601003700 split ai_tag_provider from ai_tag_status.
-- Historical rows whose provider used to be 'keyword-fallback' lost their
-- provider identity (set to NULL with ai_tag_status='fallback'), because we
-- never recorded which LLM was attempted on those runs. Now that AI_PROVIDER
-- is wired up (Ollama), enqueue those rows so the next worker tick will call
-- the LLM, populate ai_tag_provider/ai_tag_model, and flip ai_tag_status to
-- 'success' for the ones that classify cleanly.
--
-- Safety:
--   * trigger_type = 'reclassify' tells tag-event to re-tag even when tags
--     already exist (vs 'import' which only fills NULL tags).
--   * ON CONFLICT DO NOTHING avoids duplicating rows for events already
--     queued (partial-unique index covers status IN ('pending','processing')).
--   * Successful runs (ai_tag_status='success') are intentionally excluded so
--     we don't churn rows that are already correctly tagged. Manual overrides
--     on event_tags are preserved by tag-event itself.

INSERT INTO public.event_tag_queue (event_id, trigger_type)
SELECT id, 'reclassify'
FROM public.events
WHERE ai_tag_status = 'fallback'
   OR ai_tag_status IS NULL
ON CONFLICT DO NOTHING;
