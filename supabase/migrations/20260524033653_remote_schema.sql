-- Guarded remote-schema cleanup.
--
-- This migration exists in hosted history, but local resets can replay it before
-- the later consolidated LLM-review tables are created. Keep every object touch
-- conditional so CI reset works from an empty local database.

CREATE EXTENSION IF NOT EXISTS "pgmq" WITH SCHEMA "pgmq";

DO $$
BEGIN
  IF to_regclass('public.event_llm_review_queue') IS NOT NULL THEN
    DROP POLICY IF EXISTS "Admins can read event llm review queue" ON public.event_llm_review_queue;

    CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_id_idx
      ON public.event_llm_review_queue USING btree (source_id)
      WHERE source_id IS NOT NULL;

    CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_run_id_idx
      ON public.event_llm_review_queue USING btree (source_run_id)
      WHERE source_run_id IS NOT NULL;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'event_llm_review_queue_trigger_type_check'
        AND conrelid = to_regclass('public.event_llm_review_queue')
    ) THEN
      ALTER TABLE public.event_llm_review_queue
        ADD CONSTRAINT event_llm_review_queue_trigger_type_check
        CHECK (trigger_type = ANY (ARRAY['import'::text, 'reclassify'::text, 'manual-review'::text]))
        NOT VALID;
    END IF;

    ALTER TABLE public.event_llm_review_queue
      VALIDATE CONSTRAINT event_llm_review_queue_trigger_type_check;

    CREATE POLICY "Admins can read event llm review queue"
      ON public.event_llm_review_queue
      AS PERMISSIVE
      FOR SELECT
      TO authenticated
      USING ((SELECT private.is_admin()));
  END IF;

  IF to_regclass('public.event_llm_review_traces') IS NOT NULL THEN
    DROP POLICY IF EXISTS "Admins can read event llm review traces" ON public.event_llm_review_traces;

    CREATE INDEX IF NOT EXISTS event_llm_review_traces_queue_id_idx
      ON public.event_llm_review_traces USING btree (queue_id)
      WHERE queue_id IS NOT NULL;

    CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_id_idx
      ON public.event_llm_review_traces USING btree (source_id)
      WHERE source_id IS NOT NULL;

    CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_run_id_idx
      ON public.event_llm_review_traces USING btree (source_run_id)
      WHERE source_run_id IS NOT NULL;

    CREATE POLICY "Admins can read event llm review traces"
      ON public.event_llm_review_traces
      AS PERMISSIVE
      FOR SELECT
      TO authenticated
      USING ((SELECT private.is_admin()));
  END IF;
END
$$;

ALTER TABLE IF EXISTS public.event_sources
  DROP CONSTRAINT IF EXISTS event_sources_scrape_interval_chk;
ALTER TABLE IF EXISTS public.events
  DROP CONSTRAINT IF EXISTS events_age_range_chk;
ALTER TABLE IF EXISTS public.events
  DROP CONSTRAINT IF EXISTS events_lat_lng_chk;
ALTER TABLE IF EXISTS public.events
  DROP CONSTRAINT IF EXISTS events_price_chk;
ALTER TABLE IF EXISTS public.invite_codes
  DROP CONSTRAINT IF EXISTS invite_codes_used_count_max_chk;
ALTER TABLE IF EXISTS public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_child_age_chk;

DROP INDEX IF EXISTS public.events_published_city_start_datetime_idx;
DROP INDEX IF EXISTS public.recommendation_signals_user_id_idx;
DROP INDEX IF EXISTS public.user_calendar_events_user_id_idx;

ALTER TABLE IF EXISTS private.cron_enabled ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS private.railway_cron_runs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF to_regclass('public.event_ai_traces') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS event_ai_traces_created_at_idx
      ON public.event_ai_traces USING btree (created_at);
  END IF;

  IF to_regclass('public.events') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS events_needing_enrichment_created_idx
      ON public.events USING btree (created_at DESC, id)
      WHERE (
        latitude IS NULL
        OR longitude IS NULL
        OR images = '[]'::jsonb
        OR jsonb_array_length(images) = 0
      );
  END IF;

  IF to_regclass('public.invite_redemption_attempts') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS invite_redemption_attempts_attempted_at_idx
      ON public.invite_redemption_attempts USING btree (attempted_at);
  END IF;

  IF to_regclass('public.invite_request_attempts') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS invite_request_attempts_attempted_at_idx
      ON public.invite_request_attempts USING btree (attempted_at);
  END IF;

  IF to_regclass('public.recommendation_signals') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS recommendation_signals_created_at_idx
      ON public.recommendation_signals USING btree (created_at);
  END IF;

  IF to_regclass('public.source_extraction_traces') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS source_extraction_traces_created_at_idx
      ON public.source_extraction_traces USING btree (created_at);
  END IF;

  IF to_regclass('public.source_runs') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS source_runs_running_started_idx
      ON public.source_runs USING btree (started_at)
      WHERE status = 'running'::text;

    CREATE INDEX IF NOT EXISTS source_runs_started_at_idx1
      ON public.source_runs USING btree (started_at);
  END IF;

  IF to_regclass('public.source_scrape_queue') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS source_scrape_queue_finished_at_idx
      ON public.source_scrape_queue USING btree (finished_at);
  END IF;
END
$$;

ALTER TABLE IF EXISTS public.event_sources
  ADD CONSTRAINT event_sources_scrape_interval_chk
  CHECK (scrape_interval_hours >= 1 AND scrape_interval_hours <= 720)
  NOT VALID;
ALTER TABLE IF EXISTS public.event_sources
  VALIDATE CONSTRAINT event_sources_scrape_interval_chk;

ALTER TABLE IF EXISTS public.events
  ADD CONSTRAINT events_age_range_chk
  CHECK (
    (age_min IS NULL OR age_min >= 0)
    AND (age_max IS NULL OR age_max >= 0)
    AND (age_min IS NULL OR age_max IS NULL OR age_min <= age_max)
  )
  NOT VALID;
ALTER TABLE IF EXISTS public.events
  VALIDATE CONSTRAINT events_age_range_chk;

ALTER TABLE IF EXISTS public.events
  ADD CONSTRAINT events_lat_lng_chk
  CHECK (
    (latitude IS NULL OR (latitude >= -90 AND latitude <= 90))
    AND (longitude IS NULL OR (longitude >= -180 AND longitude <= 180))
  )
  NOT VALID;
ALTER TABLE IF EXISTS public.events
  VALIDATE CONSTRAINT events_lat_lng_chk;

ALTER TABLE IF EXISTS public.events
  ADD CONSTRAINT events_price_chk
  CHECK (price IS NULL OR price >= 0)
  NOT VALID;
ALTER TABLE IF EXISTS public.events
  VALIDATE CONSTRAINT events_price_chk;

ALTER TABLE IF EXISTS public.invite_codes
  ADD CONSTRAINT invite_codes_used_count_max_chk
  CHECK (used_count <= max_uses)
  NOT VALID;
ALTER TABLE IF EXISTS public.invite_codes
  VALIDATE CONSTRAINT invite_codes_used_count_max_chk;

ALTER TABLE IF EXISTS public.user_profiles
  ADD CONSTRAINT user_profiles_child_age_chk
  CHECK (child_age IS NULL OR (child_age >= 0 AND child_age <= 18))
  NOT VALID;
ALTER TABLE IF EXISTS public.user_profiles
  VALIDATE CONSTRAINT user_profiles_child_age_chk;

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION private.admin_railway_cron_run_history(
  p_label text DEFAULT NULL::text,
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  id bigint,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamp with time zone
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'admin access required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT *
  FROM private.railway_cron_run_history(p_label, p_limit);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_history(
  p_label text DEFAULT NULL::text,
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  id bigint,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamp with time zone
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
  SELECT *
  FROM private.admin_railway_cron_run_history(p_label, p_limit);
$function$;

CREATE OR REPLACE FUNCTION public.is_enabled_user()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
  SELECT private.has_enabled_access();
$function$;
