-- Allow the event-tagging pipeline to record self-hosted OpenAI-compatible
-- providers used for local-model experiments.

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_ai_tag_provider_check;

ALTER TABLE public.events
  ADD CONSTRAINT events_ai_tag_provider_check
  CHECK (
    ai_tag_provider IS NULL OR ai_tag_provider IN (
      'openai',
      'ollama',
      'localai',
      'keyword-fallback'
    )
  );

ALTER TABLE public.event_ai_traces
  DROP CONSTRAINT IF EXISTS event_ai_traces_provider_check;

ALTER TABLE public.event_ai_traces
  ADD CONSTRAINT event_ai_traces_provider_check
  CHECK (provider IN ('openai', 'ollama', 'localai', 'keyword-fallback'));
