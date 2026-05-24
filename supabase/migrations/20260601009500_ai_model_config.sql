-- ─── approved_ai_models ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.approved_ai_models (
  id           text PRIMARY KEY,
  provider     text NOT NULL CHECK (provider IN ('openai', 'ollama', 'localai')),
  display_name text NOT NULL,
  description  text NOT NULL DEFAULT '',
  cost_tier    text NOT NULL DEFAULT 'medium'
                 CHECK (cost_tier IN ('low', 'medium', 'high')),
  is_enabled   bool NOT NULL DEFAULT true
);

INSERT INTO public.approved_ai_models (id, provider, display_name, description, cost_tier)
VALUES
  ('gpt-4.1-nano', 'openai', 'GPT-4.1 Nano',
   'Fastest and cheapest 4.1-family model. Recommended for high-volume tagging.',
   'low'),
  ('gpt-4o-mini',  'openai', 'GPT-4o mini',
   'Proven prior default for structured extraction. Strong reliability.',
   'low'),
  ('gpt-4.1-mini', 'openai', 'GPT-4.1 mini',
   'Step up from Nano when higher accuracy is needed.',
   'medium'),
  ('gpt-4.1',      'openai', 'GPT-4.1',
   'Full 4.1 model. Recommended for event review requiring nuanced reasoning.',
   'high'),
  ('gpt-4o',       'openai', 'GPT-4o',
   'Premium OpenAI fallback.',
   'high'),
  ('qwen3:1.7b',   'ollama', 'Qwen3 1.7B (local)',
   'Self-hosted default. Fastest local option.',
   'low'),
  ('qwen3:4b',     'ollama', 'Qwen3 4B (local)',
   'Higher-quality self-hosted model.',
   'medium')
ON CONFLICT (id) DO UPDATE SET
  provider     = EXCLUDED.provider,
  display_name = EXCLUDED.display_name,
  description  = EXCLUDED.description,
  cost_tier    = EXCLUDED.cost_tier,
  is_enabled   = true;

-- ─── ai_feature_config ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ai_feature_config (
  feature    text PRIMARY KEY
               CHECK (feature IN ('tagging', 'event-review')),
  model_id   text NOT NULL REFERENCES public.approved_ai_models (id),
  enabled    bool NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users (id)
);

INSERT INTO public.ai_feature_config (feature, model_id, enabled)
VALUES
  ('tagging',      'gpt-4.1-nano', true),
  ('event-review', 'gpt-4.1',      false)
ON CONFLICT (feature) DO UPDATE SET
  model_id = EXCLUDED.model_id,
  enabled  = EXCLUDED.enabled;

-- ─── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.approved_ai_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_feature_config   ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.approved_ai_models TO anon, authenticated, service_role;
GRANT SELECT ON public.ai_feature_config TO authenticated, service_role;

DROP POLICY IF EXISTS "anon read approved_ai_models" ON public.approved_ai_models;
DROP POLICY IF EXISTS "authenticated read approved_ai_models" ON public.approved_ai_models;
DROP POLICY IF EXISTS "authenticated read ai_feature_config" ON public.ai_feature_config;

CREATE POLICY "authenticated read approved_ai_models"
  ON public.approved_ai_models FOR SELECT TO authenticated USING (true);

CREATE POLICY "anon read approved_ai_models"
  ON public.approved_ai_models FOR SELECT TO anon USING (true);

CREATE POLICY "authenticated read ai_feature_config"
  ON public.ai_feature_config FOR SELECT TO authenticated USING (true);

-- ─── prompt_version column on event_ai_traces ───────────────────────────────
ALTER TABLE public.event_ai_traces
  ADD COLUMN IF NOT EXISTS prompt_version text;

-- ─── private.upsert_ai_feature_config ───────────────────────────────────────
CREATE OR REPLACE FUNCTION private.upsert_ai_feature_config(
  p_feature  text,
  p_model_id text,
  p_enabled  bool
) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_feature NOT IN ('tagging', 'event-review') THEN
    RAISE EXCEPTION 'invalid feature: %', p_feature;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.approved_ai_models
    WHERE id = p_model_id AND is_enabled = true
  ) THEN
    RAISE EXCEPTION 'model % not found or disabled', p_model_id;
  END IF;

  INSERT INTO public.ai_feature_config (feature, model_id, enabled, updated_at, updated_by)
  VALUES (p_feature, p_model_id, p_enabled, now(), auth.uid())
  ON CONFLICT (feature) DO UPDATE SET
    model_id   = EXCLUDED.model_id,
    enabled    = EXCLUDED.enabled,
    updated_at = now(),
    updated_by = auth.uid();
END;
$$;

-- ─── public.upsert_ai_feature_config (SECURITY INVOKER wrapper) ─────────────
CREATE OR REPLACE FUNCTION public.upsert_ai_feature_config(
  p_feature  text,
  p_model_id text,
  p_enabled  bool DEFAULT true
) RETURNS void
  LANGUAGE sql
  SECURITY INVOKER
  SET search_path = ''
AS $$
  SELECT private.upsert_ai_feature_config(p_feature, p_model_id, p_enabled);
$$;

REVOKE EXECUTE ON FUNCTION public.upsert_ai_feature_config(text, text, bool)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_ai_feature_config(text, text, bool)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  TO authenticated, service_role;

-- ─── public.get_approved_ai_models ──────────────────────────────────────────
-- No private wrapper needed — no elevated privileges required.
CREATE OR REPLACE FUNCTION public.get_approved_ai_models()
RETURNS TABLE (
  id           text,
  provider     text,
  display_name text,
  description  text,
  cost_tier    text
)
  LANGUAGE sql
  STABLE
  SECURITY INVOKER
  SET search_path = ''
AS $$
  SELECT id, provider, display_name, description, cost_tier
  FROM public.approved_ai_models
  WHERE is_enabled = true
  ORDER BY provider, cost_tier, id;
$$;

GRANT EXECUTE ON FUNCTION public.get_approved_ai_models()
  TO authenticated, service_role, anon;

-- ─── Verify ─────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT has_table_privilege('authenticated', 'public.approved_ai_models', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated missing SELECT on approved_ai_models';
  END IF;

  IF NOT has_table_privilege('anon', 'public.approved_ai_models', 'SELECT') THEN
    RAISE EXCEPTION 'anon missing SELECT on approved_ai_models';
  END IF;

  PERFORM public.get_approved_ai_models();
END $$;
