-- Record the specific LLM model that produced an event's AI tags so the admin
-- list view can show "Provider · Model" without joining event_ai_traces.

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS ai_tag_model text;

COMMENT ON COLUMN public.events.ai_tag_model IS
  'Concrete model identifier (e.g. gpt-4o-mini, qwen3:1.7b, gemma4:e4b) used to generate ai_tag_provider classification. NULL when no AI tagging ran.';
