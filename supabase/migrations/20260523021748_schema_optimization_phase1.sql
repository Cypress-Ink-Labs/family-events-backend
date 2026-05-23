-- LLM review FK coverage indexes.
CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_id_idx
ON public.event_llm_review_queue USING btree (source_id)
WHERE source_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_run_id_idx
ON public.event_llm_review_queue USING btree (source_run_id)
WHERE source_run_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS event_llm_review_traces_queue_id_idx
ON public.event_llm_review_traces USING btree (queue_id)
WHERE queue_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_id_idx
ON public.event_llm_review_traces USING btree (source_id)
WHERE source_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_run_id_idx
ON public.event_llm_review_traces USING btree (source_run_id)
WHERE source_run_id IS NOT NULL;

-- Retention and maintenance indexes.
CREATE INDEX IF NOT EXISTS invite_request_attempts_attempted_at_idx
ON public.invite_request_attempts USING btree (attempted_at);

CREATE INDEX IF NOT EXISTS invite_redemption_attempts_attempted_at_idx
ON public.invite_redemption_attempts USING btree (attempted_at);

CREATE INDEX IF NOT EXISTS recommendation_signals_created_at_idx
ON public.recommendation_signals USING btree (created_at);

CREATE INDEX IF NOT EXISTS event_ai_traces_created_at_idx
ON public.event_ai_traces USING btree (created_at);

CREATE INDEX IF NOT EXISTS source_extraction_traces_created_at_idx
ON public.source_extraction_traces USING btree (created_at);

CREATE INDEX IF NOT EXISTS source_runs_running_started_idx
ON public.source_runs USING btree (started_at)
WHERE status = 'running';

CREATE INDEX IF NOT EXISTS events_needing_enrichment_created_idx
ON public.events USING btree (created_at DESC, id)
WHERE (
  latitude IS NULL
  OR longitude IS NULL
  OR images = '[]'::jsonb
  OR jsonb_array_length(images) = 0
);

-- Cache fixed helper calls in RLS predicates.
ALTER POLICY "Admins can read event llm review queue"
ON public.event_llm_review_queue
USING ((SELECT private.is_admin()));

ALTER POLICY "Admins can read event llm review traces"
ON public.event_llm_review_traces
USING ((SELECT private.is_admin()));

-- Restrict trigger-only or service-only public function execution.
REVOKE EXECUTE ON FUNCTION public.handle_new_user()
FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.prevent_role_change()
FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.reset_comment_approval_for_non_admin()
FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.invoke_process_tag_queue()
FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.invoke_scrape_source(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.run_due_source_scrapes()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.invoke_process_tag_queue() TO service_role;
GRANT EXECUTE ON FUNCTION public.invoke_scrape_source(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.run_due_source_scrapes() TO service_role;

-- Convert public is_enabled_user RPC to invoker wrapper.
CREATE OR REPLACE FUNCTION public.is_enabled_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.has_enabled_access();
$$;

REVOKE EXECUTE ON FUNCTION public.is_enabled_user()
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.is_enabled_user()
TO anon, authenticated, service_role;

-- Add private admin body and convert public admin_railway_cron_run_history to invoker wrapper.
CREATE OR REPLACE FUNCTION private.admin_railway_cron_run_history(
  p_label text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  id bigint,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'admin access required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT *
  FROM private.railway_cron_run_history(p_label, p_limit);
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_railway_cron_run_history(text, integer)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION private.admin_railway_cron_run_history(text, integer)
TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_history(
  p_label text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  id bigint,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT *
  FROM private.admin_railway_cron_run_history(p_label, p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.admin_railway_cron_run_history(text, integer)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_railway_cron_run_history(text, integer)
TO authenticated, service_role;

-- Validate existing NOT VALID constraints.
ALTER TABLE public.event_sources
VALIDATE CONSTRAINT event_sources_scrape_interval_chk;

ALTER TABLE public.events
VALIDATE CONSTRAINT events_age_range_chk;

ALTER TABLE public.events
VALIDATE CONSTRAINT events_lat_lng_chk;

ALTER TABLE public.events
VALIDATE CONSTRAINT events_price_chk;

ALTER TABLE public.invite_codes
VALIDATE CONSTRAINT invite_codes_used_count_max_chk;

ALTER TABLE public.user_profiles
VALIDATE CONSTRAINT user_profiles_child_age_chk;

-- Add and validate LLM queue trigger type check constraint.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_llm_review_queue_trigger_type_check'
      AND conrelid = 'public.event_llm_review_queue'::regclass
  ) THEN
    ALTER TABLE public.event_llm_review_queue
    ADD CONSTRAINT event_llm_review_queue_trigger_type_check
    CHECK (
      trigger_type = ANY (ARRAY['import'::text, 'reclassify'::text, 'manual-review'::text])
    ) NOT VALID;
  END IF;
END;
$$;

ALTER TABLE public.event_llm_review_queue
VALIDATE CONSTRAINT event_llm_review_queue_trigger_type_check;

-- Enable RLS on private cron state tables.
ALTER TABLE private.railway_cron_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.cron_enabled ENABLE ROW LEVEL SECURITY;
