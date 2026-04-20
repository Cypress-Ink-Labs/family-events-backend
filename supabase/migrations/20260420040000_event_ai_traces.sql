/*
  # Add event AI classification traces

  Records the latest background tagging explanation data so admins can inspect
  what the classifier suggested, why it suggested it, and whether the system
  fell back from OpenAI to keyword rules.
*/

CREATE TABLE IF NOT EXISTS public.event_ai_traces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  source_run_id uuid REFERENCES public.source_runs(id) ON DELETE SET NULL,
  trigger_type text NOT NULL DEFAULT 'import'
    CHECK (trigger_type IN ('import', 'reclassify', 'manual-review')),
  provider text NOT NULL
    CHECK (provider IN ('openai', 'keyword-fallback')),
  model text,
  status text NOT NULL DEFAULT 'success'
    CHECK (status IN ('success', 'fallback', 'error')),
  input_title text NOT NULL,
  input_description text,
  available_tag_slugs jsonb NOT NULL DEFAULT '[]'::jsonb,
  predicted_tags jsonb NOT NULL DEFAULT '[]'::jsonb,
  predicted_fields jsonb,
  reasoning_summary text,
  fallback_reason text,
  processing_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.event_ai_traces ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS event_ai_traces_event_id_created_at_idx
  ON public.event_ai_traces(event_id, created_at DESC);

CREATE INDEX IF NOT EXISTS event_ai_traces_source_run_id_idx
  ON public.event_ai_traces(source_run_id)
  WHERE source_run_id IS NOT NULL;

DROP POLICY IF EXISTS "Admins can read AI traces" ON public.event_ai_traces;
CREATE POLICY "Admins can read AI traces"
  ON public.event_ai_traces FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND role = 'admin'));

COMMENT ON TABLE public.event_ai_traces IS
  'Admin-only history of AI/keyword event classification output and explanations.';

COMMENT ON COLUMN public.event_ai_traces.predicted_tags IS
  'JSON array of predicted tags with confidence and explanation evidence.';

COMMENT ON COLUMN public.event_ai_traces.predicted_fields IS
  'JSON object for extracted structured fields like age, price, and venue.';

