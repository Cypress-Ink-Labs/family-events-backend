/*
  # Expose AI tag provider on events

  tag-event supports two classification paths: OpenAI (high quality) and
  keyword fallback (low quality, used when OPENAI_API_KEY is missing or
  OpenAI is unreachable). Previously the admin dashboard had no way to tell
  which path ran — a silent drop to keyword fallback (e.g. expired API key)
  looked identical to a successful AI classification with low confidence.

  Admin can now filter / sort events by provider to audit tag quality.
*/

ALTER TABLE events
  ADD COLUMN IF NOT EXISTS ai_tag_provider text
    CHECK (ai_tag_provider IS NULL OR ai_tag_provider IN ('openai', 'keyword-fallback'));

COMMENT ON COLUMN events.ai_tag_provider IS
  'Which classifier tagged this event: openai (high quality) or keyword-fallback (rule-based).';

-- Index for admin panel filtering and sorting by provider
CREATE INDEX IF NOT EXISTS idx_events_ai_tag_provider
  ON events (ai_tag_provider)
  WHERE ai_tag_provider IS NOT NULL;
