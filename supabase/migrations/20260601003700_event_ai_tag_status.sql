-- Split AI tagging outcome from LLM provider identity.
--
-- Before this migration, `ai_tag_provider = 'keyword-fallback'` was used as a
-- sentinel to mean "the keyword matcher ran because no LLM produced tags".
-- That conflated two orthogonal concerns: which LLM was attempted vs. did the
-- LLM actually succeed. The admin events list rendered "Keyword fallback" in
-- the provider slot even though the row already remembered which model was
-- attempted (`ai_tag_model`), so operators couldn't see at a glance which
-- model/provider had been configured when the fallback fired.
--
-- New model:
--   ai_tag_provider : LLM provider that was attempted (openai|ollama|localai)
--                     or NULL if no provider attempt was recorded (historical).
--   ai_tag_model    : concrete model identifier that was attempted.
--   ai_tag_status   : success | fallback | error — outcome of the pipeline.
--                     NULL when no tagging has run.

-- 1. New status column on events.
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS ai_tag_status text
    CHECK (
      ai_tag_status IS NULL
      OR ai_tag_status IN ('success', 'fallback', 'error')
    );

COMMENT ON COLUMN public.events.ai_tag_status IS
  'Outcome of the AI tagging pipeline. success=LLM produced classification; fallback=LLM unavailable or failed, keyword matcher used; error=tagging errored. NULL when no tagging has run.';

-- 2. Backfill status from current provider column.
UPDATE public.events
SET ai_tag_status = 'fallback'
WHERE ai_tag_provider = 'keyword-fallback'
  AND ai_tag_status IS NULL;

UPDATE public.events
SET ai_tag_status = 'success'
WHERE ai_tag_provider IN ('openai', 'ollama', 'localai')
  AND ai_tag_status IS NULL;

-- 3. Clear the sentinel from ai_tag_provider. Historical fallback rows have
-- no record of which LLM was attempted, so NULL is the honest value.
UPDATE public.events
SET ai_tag_provider = NULL
WHERE ai_tag_provider = 'keyword-fallback';

-- 4. Tighten the provider check now that the sentinel is gone.
ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_ai_tag_provider_check;

ALTER TABLE public.events
  ADD CONSTRAINT events_ai_tag_provider_check
  CHECK (
    ai_tag_provider IS NULL
    OR ai_tag_provider IN ('openai', 'ollama', 'localai')
  );

CREATE INDEX IF NOT EXISTS idx_events_ai_tag_status
  ON public.events(ai_tag_status) WHERE ai_tag_status IS NOT NULL;

-- 5. event_ai_traces already has its own status column; mirror the same
-- cleanup for its provider column so traces no longer overload the value.
-- Drop NOT NULL because historical keyword-fallback traces have no recorded
-- provider; new rows will always populate it.
ALTER TABLE public.event_ai_traces
  ALTER COLUMN provider DROP NOT NULL;

UPDATE public.event_ai_traces
SET provider = NULL
WHERE provider = 'keyword-fallback';

ALTER TABLE public.event_ai_traces
  DROP CONSTRAINT IF EXISTS event_ai_traces_provider_check;

ALTER TABLE public.event_ai_traces
  ADD CONSTRAINT event_ai_traces_provider_check
  CHECK (
    provider IS NULL
    OR provider IN ('openai', 'ollama', 'localai')
  );
