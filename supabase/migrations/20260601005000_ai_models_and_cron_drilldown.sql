
-- ============================================================================
-- Source: 20260601009500_ai_model_config.sql
-- ============================================================================

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


-- ============================================================================
-- Source: 20260601009501_revoke_private_upsert_ai_feature_config.sql
-- ============================================================================

-- Tighten: authenticated users should not call private fn directly.
-- The public wrapper already enforces is_admin(); direct grant is unnecessary.
-- Wrapped in DO block: REVOKE has no IF EXISTS syntax.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private' AND p.proname = 'upsert_ai_feature_config'
  ) THEN
    REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
      FROM authenticated;
  END IF;
END $$;


-- ============================================================================
-- Source: 20260601009502_repair_ai_model_config.sql
-- ============================================================================

-- Repair: 9500 was recorded in schema_migrations but its DDL never executed.
-- All statements are idempotent (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT).

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

ALTER TABLE public.event_ai_traces
  ADD COLUMN IF NOT EXISTS prompt_version text;

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

-- private fn: service_role only (authenticated uses the public wrapper)
REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  TO service_role;

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


-- ============================================================================
-- Source: 20260601009503_add_gpt5_models.sql
-- ============================================================================

-- Add GPT-5.x model family. These supersede GPT-4.x for both tagging and review.
-- gpt-5.4-nano: $0.20/$1.25 per 1M — purpose-built for classification/extraction (tagging)
-- gpt-5.4-mini: $0.75/$4.50 per 1M — stronger mini for high-volume review
-- gpt-5.4:      $2.50/$15.00 per 1M — frontier model with configurable reasoning (event review)
-- gpt-5.5:      $5.00/$30.00 per 1M — overkill for this workload, added disabled

INSERT INTO public.approved_ai_models (id, provider, display_name, description, cost_tier)
VALUES
  ('gpt-5.4-nano', 'openai', 'GPT-5.4 Nano',
   'Purpose-built for classification, data extraction, and ranking. Best default for high-volume tagging. $0.20/$1.25 per 1M.',
   'low'),
  ('gpt-5.4-mini', 'openai', 'GPT-5.4 mini',
   'Strongest mini model for coding and subagents. Good mid-tier option for review. $0.75/$4.50 per 1M.',
   'low'),
  ('gpt-5.4', 'openai', 'GPT-5.4',
   'Frontier model with configurable reasoning effort (none→extra-high) and 1M context. Best for nuanced event review. $2.50/$15 per 1M.',
   'high'),
  ('gpt-5.5', 'openai', 'GPT-5.5',
   'Highest intelligence class. Overkill for tagging/review at $5/$30 per 1M. Disabled by default.',
   'high')
ON CONFLICT (id) DO UPDATE SET
  provider     = EXCLUDED.provider,
  display_name = EXCLUDED.display_name,
  description  = EXCLUDED.description,
  cost_tier    = EXCLUDED.cost_tier;

-- gpt-5.5 is available but disabled — too expensive for routine workloads
UPDATE public.approved_ai_models SET is_enabled = false WHERE id = 'gpt-5.5';

-- Mark legacy 4.x models as disabled since 5.x supersedes them.
UPDATE public.approved_ai_models
SET is_enabled = false
WHERE id IN ('gpt-4.1-nano', 'gpt-4.1-mini', 'gpt-4.1', 'gpt-4o', 'gpt-4o-mini');

-- Update ai_feature_config defaults to the new 5.x equivalents.
-- ON CONFLICT skipped — update only if the config exists and still points to a now-disabled model.
INSERT INTO public.ai_feature_config (feature, model_id, enabled)
VALUES
  ('tagging',      'gpt-5.4-nano', true),
  ('event-review', 'gpt-5.4',      false)
ON CONFLICT (feature) DO UPDATE SET
  model_id = EXCLUDED.model_id
WHERE public.ai_feature_config.model_id IN (
  'gpt-4.1-nano', 'gpt-4.1-mini', 'gpt-4.1', 'gpt-4o', 'gpt-4o-mini'
);


-- ============================================================================
-- Source: 20260601009504_cron_run_log_drilldown.sql
-- ============================================================================

BEGIN;

ALTER TABLE private.railway_cron_runs
  ADD COLUMN IF NOT EXISTS run_key uuid NOT NULL DEFAULT gen_random_uuid();

CREATE UNIQUE INDEX IF NOT EXISTS railway_cron_runs_run_key_key
  ON private.railway_cron_runs (run_key);

CREATE TABLE IF NOT EXISTS private.cron_run_log_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_key uuid NOT NULL,
  label text NOT NULL,
  provider text NOT NULL CHECK (provider IN ('railway', 'supabase')),
  level text NOT NULL CHECK (level IN ('debug', 'info', 'log', 'warn', 'error')),
  message text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  sequence integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.cron_run_log_entries ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS cron_run_log_entries_run_key_created_at_idx
  ON private.cron_run_log_entries (run_key, created_at, id);

CREATE INDEX IF NOT EXISTS cron_run_log_entries_label_created_at_idx
  ON private.cron_run_log_entries (label, created_at DESC);

REVOKE ALL ON TABLE private.cron_run_log_entries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE private.cron_run_log_entries_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.log_cron_run_event(
  p_run_key uuid,
  p_label text,
  p_provider text,
  p_level text,
  p_message text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_sequence integer DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  INSERT INTO private.cron_run_log_entries (
    run_key,
    label,
    provider,
    level,
    message,
    metadata,
    sequence
  )
  VALUES (
    p_run_key,
    left(p_label, 120),
    p_provider,
    p_level,
    left(p_message, 10000),
    COALESCE(p_metadata, '{}'::jsonb),
    p_sequence
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.log_cron_run_event(
  p_run_key uuid,
  p_label text,
  p_provider text,
  p_level text,
  p_message text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_sequence integer DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.log_cron_run_event(
    p_run_key,
    p_label,
    p_provider,
    p_level,
    p_message,
    p_metadata,
    p_sequence
  );
$$;

DROP FUNCTION IF EXISTS public.log_railway_cron_run(text, text, integer, integer, text);
DROP FUNCTION IF EXISTS public.log_railway_cron_run(text, text, integer, integer, text, uuid, text);
DROP FUNCTION IF EXISTS private.log_railway_cron_run(text, text, integer, integer, text);
DROP FUNCTION IF EXISTS private.log_railway_cron_run(text, text, integer, integer, text, uuid, text);

CREATE FUNCTION private.log_railway_cron_run(
  p_label text,
  p_status text,
  p_http_status integer DEFAULT NULL::integer,
  p_duration_s integer DEFAULT NULL::integer,
  p_body text DEFAULT NULL::text,
  p_run_key uuid DEFAULT gen_random_uuid(),
  p_runner_log text DEFAULT NULL::text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_id bigint;
  v_run_key uuid := COALESCE(p_run_key, gen_random_uuid());
BEGIN
  INSERT INTO private.railway_cron_runs (
    label,
    status,
    http_status,
    duration_s,
    body,
    run_key
  )
  VALUES (
    left(p_label, 120),
    p_status,
    p_http_status,
    p_duration_s,
    p_body,
    v_run_key
  )
  RETURNING id INTO v_id;

  PERFORM private.log_cron_run_event(
    v_run_key,
    p_label,
    'railway',
    CASE WHEN p_status = 'succeeded' THEN 'info' ELSE 'error' END,
    'runner completed',
    jsonb_strip_nulls(jsonb_build_object(
      'http_status', p_http_status,
      'duration_s', p_duration_s,
      'body', p_body,
      'runner_log', p_runner_log
    )),
    NULL
  );

  RETURN v_id;
END;
$$;

CREATE FUNCTION public.log_railway_cron_run(
  p_label text,
  p_status text,
  p_http_status integer DEFAULT NULL::integer,
  p_duration_s integer DEFAULT NULL::integer,
  p_body text DEFAULT NULL::text,
  p_run_key uuid DEFAULT gen_random_uuid(),
  p_runner_log text DEFAULT NULL::text
)
RETURNS bigint
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.log_railway_cron_run(
    p_label,
    p_status,
    p_http_status,
    p_duration_s,
    p_body,
    p_run_key,
    p_runner_log
  );
$$;

CREATE OR REPLACE FUNCTION private.railway_cron_run_detail(p_run_id bigint)
RETURNS TABLE (
  id bigint,
  run_key uuid,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamptz,
  logs jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF current_user <> 'service_role' AND NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.run_key,
    r.label,
    r.status,
    r.http_status,
    r.duration_s,
    r.body,
    r.ran_at,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', l.id,
            'provider', l.provider,
            'level', l.level,
            'message', l.message,
            'metadata', l.metadata,
            'sequence', l.sequence,
            'created_at', l.created_at
          )
          ORDER BY l.created_at, l.id
        )
        FROM private.cron_run_log_entries l
        WHERE l.run_key = r.run_key
      ),
      '[]'::jsonb
    ) AS logs
  FROM private.railway_cron_runs r
  WHERE r.id = p_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_detail(p_run_id bigint)
RETURNS TABLE (
  id bigint,
  run_key uuid,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamptz,
  logs jsonb
)
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.railway_cron_run_detail(p_run_id);
$$;

REVOKE EXECUTE ON FUNCTION private.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  TO service_role;

REVOKE EXECUTE ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  TO service_role;

REVOKE EXECUTE ON FUNCTION private.railway_cron_run_detail(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.railway_cron_run_detail(bigint)
  TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.admin_railway_cron_run_detail(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_railway_cron_run_detail(bigint)
  TO authenticated, service_role;

COMMIT;

