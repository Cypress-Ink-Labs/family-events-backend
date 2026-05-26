
-- ============================================================================
-- Source: 20260601008500_llm_event_review_processing.sql
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'event_processing_mode'
  ) THEN
    CREATE TYPE public.event_processing_mode AS ENUM (
      'manual_review',
      'auto_approve',
      'llm_review'
    );
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'llm_event_review_decision'
  ) THEN
    CREATE TYPE public.llm_event_review_decision AS ENUM (
      'approve',
      'reject',
      'needs_admin_review'
    );
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'llm_event_review_status'
  ) THEN
    CREATE TYPE public.llm_event_review_status AS ENUM (
      'not_required',
      'pending',
      'succeeded',
      'failed',
      'skipped'
    );
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'llm_event_review_queue_status'
  ) THEN
    CREATE TYPE public.llm_event_review_queue_status AS ENUM (
      'pending',
      'processing',
      'retrying',
      'succeeded',
      'dead'
    );
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- event_sources
-- ---------------------------------------------------------------------------
ALTER TABLE public.event_sources
  ADD COLUMN IF NOT EXISTS processing_mode public.event_processing_mode;

UPDATE public.event_sources
SET processing_mode = CASE
  WHEN auto_approve THEN 'auto_approve'::public.event_processing_mode
  ELSE 'manual_review'::public.event_processing_mode
END
WHERE processing_mode IS NULL
   OR processing_mode = 'manual_review'::public.event_processing_mode;

ALTER TABLE public.event_sources
  ALTER COLUMN processing_mode SET DEFAULT 'manual_review'::public.event_processing_mode,
  ALTER COLUMN processing_mode SET NOT NULL;

CREATE INDEX IF NOT EXISTS event_sources_processing_mode_idx
  ON public.event_sources (processing_mode, is_active, id);

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS llm_review_status public.llm_event_review_status,
  ADD COLUMN IF NOT EXISTS llm_review_decision public.llm_event_review_decision,
  ADD COLUMN IF NOT EXISTS llm_review_confidence numeric(4,3),
  ADD COLUMN IF NOT EXISTS llm_review_reason text,
  ADD COLUMN IF NOT EXISTS llm_review_flags text[] DEFAULT '{}'::text[] NOT NULL,
  ADD COLUMN IF NOT EXISTS llm_review_provider text,
  ADD COLUMN IF NOT EXISTS llm_review_model text,
  ADD COLUMN IF NOT EXISTS llm_review_prompt_version text,
  ADD COLUMN IF NOT EXISTS llm_reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS llm_review_error text;

UPDATE public.events
SET llm_review_status = 'not_required'::public.llm_event_review_status
WHERE llm_review_status IS NULL;

ALTER TABLE public.events
  ALTER COLUMN llm_review_status SET DEFAULT 'not_required'::public.llm_event_review_status,
  ALTER COLUMN llm_review_status SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'events_llm_review_confidence_range'
      AND conrelid = 'public.events'::regclass
  ) THEN
    ALTER TABLE public.events
      ADD CONSTRAINT events_llm_review_confidence_range
      CHECK (llm_review_confidence IS NULL OR (llm_review_confidence >= 0 AND llm_review_confidence <= 1));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'events_llm_review_reason_required_when_decided'
      AND conrelid = 'public.events'::regclass
  ) THEN
    ALTER TABLE public.events
      ADD CONSTRAINT events_llm_review_reason_required_when_decided
      CHECK (
        llm_review_decision IS NULL
        OR NULLIF(trim(COALESCE(llm_review_reason, '')), '') IS NOT NULL
      );
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS events_llm_review_status_created_idx
  ON public.events (llm_review_status, created_at DESC, id);

CREATE INDEX IF NOT EXISTS events_llm_review_decision_created_idx
  ON public.events (llm_review_decision, created_at DESC, id)
  WHERE llm_review_decision IS NOT NULL;

-- ---------------------------------------------------------------------------
-- LLM review queue + traces
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.event_llm_review_queue (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  source_id uuid REFERENCES public.event_sources(id) ON DELETE SET NULL,
  source_run_id uuid REFERENCES public.source_runs(id) ON DELETE SET NULL,
  trigger_type text NOT NULL DEFAULT 'import',
  status public.llm_event_review_queue_status NOT NULL DEFAULT 'pending',
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 3,
  enqueued_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.event_llm_review_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_llm_review_queue FORCE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX IF NOT EXISTS event_llm_review_queue_active_event_idx
  ON public.event_llm_review_queue (event_id)
  WHERE status IN ('pending', 'processing', 'retrying');

CREATE INDEX IF NOT EXISTS event_llm_review_queue_claim_idx
  ON public.event_llm_review_queue (status, next_attempt_at, enqueued_at, id)
  WHERE status IN ('pending', 'retrying');

CREATE INDEX IF NOT EXISTS event_llm_review_queue_event_idx
  ON public.event_llm_review_queue (event_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.event_llm_review_traces (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  queue_id bigint REFERENCES public.event_llm_review_queue(id) ON DELETE SET NULL,
  source_id uuid REFERENCES public.event_sources(id) ON DELETE SET NULL,
  source_run_id uuid REFERENCES public.source_runs(id) ON DELETE SET NULL,
  provider text,
  model text,
  prompt_version text NOT NULL,
  status public.llm_event_review_status NOT NULL,
  model_decision public.llm_event_review_decision,
  applied_decision public.llm_event_review_decision,
  confidence numeric(4,3),
  reason text,
  flags text[] NOT NULL DEFAULT '{}'::text[],
  suggested_category text,
  normalized_title text,
  raw_response jsonb,
  error_code text,
  error_message text,
  input_snapshot jsonb,
  processing_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.event_llm_review_traces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_llm_review_traces FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'event_llm_review_traces_confidence_range'
      AND conrelid = 'public.event_llm_review_traces'::regclass
  ) THEN
    ALTER TABLE public.event_llm_review_traces
      ADD CONSTRAINT event_llm_review_traces_confidence_range
      CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1));
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS event_llm_review_traces_event_created_idx
  ON public.event_llm_review_traces (event_id, created_at DESC);

CREATE INDEX IF NOT EXISTS event_llm_review_traces_status_created_idx
  ON public.event_llm_review_traces (status, created_at DESC);

DROP VIEW IF EXISTS public.event_llm_review_queue_summary;
CREATE VIEW public.event_llm_review_queue_summary WITH (security_invoker='true') AS
SELECT
  status,
  COUNT(*)::integer AS row_count,
  MIN(enqueued_at) FILTER (WHERE status IN ('pending', 'retrying')) AS oldest_pending_enqueued_at,
  MIN(started_at) FILTER (WHERE status = 'processing') AS oldest_processing_started_at,
  MAX(finished_at) FILTER (WHERE status = 'dead') AS last_dead_letter_at,
  AVG(attempt_count)::numeric(10,2) AS avg_attempts
FROM public.event_llm_review_queue
GROUP BY status;

-- ---------------------------------------------------------------------------
-- RLS policies
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Admins can read event llm review queue" ON public.event_llm_review_queue;
CREATE POLICY "Admins can read event llm review queue"
  ON public.event_llm_review_queue
  FOR SELECT
  TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can read event llm review traces" ON public.event_llm_review_traces;
CREATE POLICY "Admins can read event llm review traces"
  ON public.event_llm_review_traces
  FOR SELECT
  TO authenticated
  USING (private.is_admin());

-- ---------------------------------------------------------------------------
-- Queue helper RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.claim_event_llm_review_queue_batch(
  p_limit integer DEFAULT 20
)
RETURNS SETOF public.event_llm_review_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  RETURN QUERY
  UPDATE public.event_llm_review_queue q
  SET status = 'processing',
      started_at = NULL,
      updated_at = now()
  WHERE q.id IN (
    SELECT i.id
    FROM public.event_llm_review_queue i
    WHERE i.status IN ('pending', 'retrying')
      AND i.next_attempt_at <= now()
    ORDER BY i.next_attempt_at, i.enqueued_at, i.id
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(p_limit, 100))
  )
  RETURNING *;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_event_llm_review_queue_batch(
  p_limit integer DEFAULT 20
)
RETURNS SETOF public.event_llm_review_queue
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.claim_event_llm_review_queue_batch(p_limit);
$$;

CREATE OR REPLACE FUNCTION private.mark_event_llm_review_queue_row_started(
  p_queue_id bigint
)
RETURNS public.event_llm_review_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_row public.event_llm_review_queue;
BEGIN
  UPDATE public.event_llm_review_queue
  SET started_at = now(),
      attempt_count = attempt_count + 1,
      updated_at = now()
  WHERE id = p_queue_id
    AND status = 'processing'
    AND started_at IS NULL
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_event_llm_review_queue_row_started(
  p_queue_id bigint
)
RETURNS public.event_llm_review_queue
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.mark_event_llm_review_queue_row_started(p_queue_id);
$$;

CREATE OR REPLACE FUNCTION private.release_unstarted_event_llm_review_rows(
  p_claimed_ids bigint[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.event_llm_review_queue
  SET status = 'pending',
      started_at = NULL,
      updated_at = now()
  WHERE id = ANY(p_claimed_ids)
    AND status = 'processing'
    AND started_at IS NULL
    AND finished_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_unstarted_event_llm_review_rows(
  p_claimed_ids bigint[]
)
RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.release_unstarted_event_llm_review_rows(p_claimed_ids);
$$;

CREATE OR REPLACE FUNCTION private.reap_stuck_event_llm_review_rows()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.event_llm_review_queue
  SET status = 'retrying',
      started_at = NULL,
      last_error = COALESCE(last_error, 'reaped after stuck in processing'),
      updated_at = now()
  WHERE status = 'processing'
    AND (
      (started_at IS NULL AND next_attempt_at < now() - interval '5 minutes')
      OR started_at < now() - interval '15 minutes'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.reap_stuck_event_llm_review_rows()
RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.reap_stuck_event_llm_review_rows();
$$;

CREATE OR REPLACE FUNCTION public.invoke_process_event_review_queue()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_supabase_url text;
  v_service_role text;
  v_reaped int;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_project_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
  END IF;

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping process-event-review-queue: missing supabase_url or service_role_key';
    RETURN;
  END IF;

  v_reaped := public.reap_stuck_event_llm_review_rows();
  IF v_reaped > 0 THEN
    RAISE NOTICE 'reaped % stuck event-review-queue rows', v_reaped;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.event_llm_review_queue WHERE status = 'processing' LIMIT 1
  ) THEN
    RAISE NOTICE 'process-event-review-queue: batch already in flight, skipping tick';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_llm_review_queue
    WHERE status IN ('pending', 'retrying')
      AND next_attempt_at <= now()
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url                  := v_supabase_url || '/functions/v1/process-event-review-queue',
    headers              := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body                 := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin processing mode RPCs + status update RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.admin_bulk_set_processing_mode(
  p_mode public.event_processing_mode
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_sources
  SET processing_mode = p_mode,
      auto_approve = (p_mode = 'auto_approve'::public.event_processing_mode),
      updated_at = now();
  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'bulk_set_processing_mode',
    'event_sources',
    jsonb_build_object('processing_mode', p_mode::text, 'affected_count', affected)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_bulk_set_processing_mode(
  p_mode public.event_processing_mode
)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.admin_bulk_set_processing_mode(p_mode);
$$;

CREATE OR REPLACE FUNCTION private.admin_bulk_set_auto_approve(enable boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_sources
  SET auto_approve = enable,
      processing_mode = CASE
        WHEN enable THEN 'auto_approve'::public.event_processing_mode
        ELSE 'manual_review'::public.event_processing_mode
      END,
      updated_at = now();
  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'bulk_set_auto_approve',
    'event_sources',
    jsonb_build_object('enable', enable, 'affected_count', affected)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_bulk_set_auto_approve(enable boolean)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.admin_bulk_set_auto_approve(enable);
$$;

CREATE OR REPLACE FUNCTION private.admin_set_event_source_processing_mode(
  p_source_id uuid,
  p_mode public.event_processing_mode
)
RETURNS public.event_sources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  before_row public.event_sources%ROWTYPE;
  updated_row public.event_sources%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO before_row
  FROM public.event_sources
  WHERE id = p_source_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source not found: %', p_source_id USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.event_sources
  SET processing_mode = p_mode,
      auto_approve = (p_mode = 'auto_approve'::public.event_processing_mode),
      updated_at = now()
  WHERE id = p_source_id
  RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'source.processing_mode.update',
    'event_source',
    p_source_id,
    jsonb_build_object(
      'previous_processing_mode', before_row.processing_mode::text,
      'processing_mode', p_mode::text,
      'previous_auto_approve', before_row.auto_approve,
      'auto_approve', updated_row.auto_approve
    )
  );

  RETURN updated_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_event_source_processing_mode(
  p_source_id uuid,
  p_mode public.event_processing_mode
)
RETURNS public.event_sources
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_set_event_source_processing_mode(p_source_id, p_mode);
$$;

CREATE OR REPLACE FUNCTION private.admin_update_event_status(
  p_event_id uuid,
  p_status text,
  p_reason text DEFAULT NULL
)
RETURNS public.events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  before_row public.events%ROWTYPE;
  updated_row public.events%ROWTYPE;
  v_reason text;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_status <> ALL (ARRAY['draft', 'published', 'rejected', 'archived']) THEN
    RAISE EXCEPTION 'invalid event status: %', p_status USING ERRCODE = '22023';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');

  SELECT * INTO before_row
  FROM public.events
  WHERE id = p_event_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event not found: %', p_event_id USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.events
  SET status = p_status,
      admin_last_edited_at = now(),
      admin_last_edited_by = auth.uid(),
      updated_at = now()
  WHERE id = p_event_id
  RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'event.status.update',
    'event',
    p_event_id,
    jsonb_build_object(
      'previous_status', before_row.status,
      'status', updated_row.status,
      'reason', v_reason,
      'previous_llm_review_status', before_row.llm_review_status,
      'llm_review_status', updated_row.llm_review_status,
      'previous_llm_review_decision', before_row.llm_review_decision,
      'llm_review_decision', updated_row.llm_review_decision
    )
  );

  RETURN updated_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_event_status(
  p_event_id uuid,
  p_status text,
  p_reason text DEFAULT NULL
)
RETURNS public.events
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_update_event_status(p_event_id, p_status, p_reason);
$$;

-- ---------------------------------------------------------------------------
-- Admin events RPC with LLM filters and projections
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int);
DROP FUNCTION IF EXISTS public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int);

CREATE OR REPLACE FUNCTION private.admin_events_enriched(
  p_status               text                              DEFAULT NULL::text,
  p_city_id              uuid                              DEFAULT NULL::uuid,
  p_city_is_null         boolean                           DEFAULT NULL::boolean,
  p_keyword              text                              DEFAULT NULL::text,
  p_after_created_at     timestamptz                       DEFAULT NULL::timestamptz,
  p_after_id             uuid                              DEFAULT NULL::uuid,
  p_limit                int                               DEFAULT 50,
  p_llm_review_status    public.llm_event_review_status    DEFAULT NULL::public.llm_event_review_status,
  p_llm_review_decision  public.llm_event_review_decision  DEFAULT NULL::public.llm_event_review_decision
)
RETURNS TABLE (
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamptz,
  end_datetime          timestamptz,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               int,
  age_max               int,
  price                 numeric,
  is_free               boolean,
  source_url            text,
  source_name           text,
  source_id             uuid,
  images                jsonb,
  status                text,
  ai_confidence         numeric,
  ai_tag_provider       text,
  recurrence_info       jsonb,
  is_featured           boolean,
  view_count            int,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamptz,
  admin_last_edited_by  uuid,
  created_at            timestamptz,
  updated_at            timestamptz,
  ai_tag_model          text,
  ai_tag_status         text,
  llm_review_status     public.llm_event_review_status,
  llm_review_decision   public.llm_event_review_decision,
  llm_review_confidence numeric(4,3),
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamptz,
  llm_review_error      text,
  total_count           bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH search_input AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE btrim(p_keyword)
      END AS kw,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::tsquery
        ELSE websearch_to_tsquery('english', btrim(p_keyword))
      END AS tsq,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE replace(replace(replace(btrim(p_keyword), '\\', '\\\\'), '%', '\\%'), '_', '\\_')
      END AS escaped_kw,
      LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500) AS page_size
  ),
  base AS (
    SELECT e.*
    FROM public.events e
    CROSS JOIN search_input si
    WHERE
      (p_status IS NULL OR e.status = p_status)
      AND (
        p_city_is_null IS NULL
        OR (p_city_is_null = true  AND e.city_id IS NULL)
        OR (p_city_is_null = false AND e.city_id IS NOT NULL)
      )
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (p_llm_review_status IS NULL OR e.llm_review_status = p_llm_review_status)
      AND (p_llm_review_decision IS NULL OR e.llm_review_decision = p_llm_review_decision)
      AND (
        si.kw IS NULL
        OR (
          si.tsq IS NOT NULL
          AND numnode(si.tsq) > 0
          AND e.search_vector @@ si.tsq
        )
        OR (
          si.escaped_kw IS NOT NULL
          AND (si.tsq IS NULL OR numnode(si.tsq) = 0 OR length(si.kw) < 3)
          AND (
            e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
            OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
          )
        )
      )
  ),
  base_count AS (
    SELECT COUNT(*)::bigint AS total_count FROM base
  ),
  page AS (
    SELECT b.*, c.total_count
    FROM base b
    CROSS JOIN base_count c
    WHERE (
      p_after_created_at IS NULL
      OR (
        p_after_id IS NULL
        AND b.created_at < p_after_created_at
      )
      OR (
        p_after_id IS NOT NULL
        AND (b.created_at, b.id) < (p_after_created_at, p_after_id)
      )
    )
    ORDER BY b.created_at DESC, b.id DESC
    LIMIT (SELECT page_size FROM search_input)
  )
  SELECT
    p.id, p.title, p.description, p.start_datetime, p.end_datetime, p.timezone,
    p.venue_name, p.address, p.city_id, p.latitude, p.longitude,
    p.age_min, p.age_max, p.price, p.is_free,
    p.source_url, p.source_name, p.source_id, p.images, p.status,
    p.ai_confidence, p.ai_tag_provider, p.recurrence_info, p.is_featured, p.view_count,
    p.search_vector, p.admin_locked_fields, p.admin_last_edited_at, p.admin_last_edited_by,
    p.created_at, p.updated_at, p.ai_tag_model, p.ai_tag_status,
    p.llm_review_status, p.llm_review_decision, p.llm_review_confidence, p.llm_review_reason,
    p.llm_review_flags, p.llm_review_provider, p.llm_review_model, p.llm_review_prompt_version,
    p.llm_reviewed_at, p.llm_review_error,
    p.total_count
  FROM page p;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_events_enriched(
  p_status               text                              DEFAULT NULL::text,
  p_city_id              uuid                              DEFAULT NULL::uuid,
  p_city_is_null         boolean                           DEFAULT NULL::boolean,
  p_keyword              text                              DEFAULT NULL::text,
  p_after_created_at     timestamptz                       DEFAULT NULL::timestamptz,
  p_after_id             uuid                              DEFAULT NULL::uuid,
  p_limit                int                               DEFAULT 50,
  p_llm_review_status    public.llm_event_review_status    DEFAULT NULL::public.llm_event_review_status,
  p_llm_review_decision  public.llm_event_review_decision  DEFAULT NULL::public.llm_event_review_decision
)
RETURNS TABLE (
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamptz,
  end_datetime          timestamptz,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               int,
  age_max               int,
  price                 numeric,
  is_free               boolean,
  source_url            text,
  source_name           text,
  source_id             uuid,
  images                jsonb,
  status                text,
  ai_confidence         numeric,
  ai_tag_provider       text,
  recurrence_info       jsonb,
  is_featured           boolean,
  view_count            int,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamptz,
  admin_last_edited_by  uuid,
  created_at            timestamptz,
  updated_at            timestamptz,
  ai_tag_model          text,
  ai_tag_status         text,
  llm_review_status     public.llm_event_review_status,
  llm_review_decision   public.llm_event_review_decision,
  llm_review_confidence numeric(4,3),
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamptz,
  llm_review_error      text,
  total_count           bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_events_enriched(
    p_status,
    p_city_id,
    p_city_is_null,
    p_keyword,
    p_after_created_at,
    p_after_id,
    p_limit,
    p_llm_review_status,
    p_llm_review_decision
  );
$$;

-- ---------------------------------------------------------------------------
-- Bulk import RPC override (processing_mode aware)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.bulk_import_scrape_events(
  p_run_id    uuid,
  p_source_id uuid,
  p_events    jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_auto_approve   boolean;
  v_processing_mode public.event_processing_mode;
  v_imported       int := 0;
  v_updated        int := 0;
  v_skipped        int := 0;
  v_enqueued       int := 0;
BEGIN
  SELECT
    auto_approve,
    processing_mode
  INTO
    v_auto_approve,
    v_processing_mode
  FROM public.event_sources
  WHERE id = p_source_id;

  IF v_auto_approve IS NULL AND v_processing_mode IS NULL THEN
    RAISE EXCEPTION 'source not found: %', p_source_id USING ERRCODE = 'P0002';
  END IF;

  IF v_processing_mode IS NULL THEN
    v_processing_mode := CASE
      WHEN COALESCE(v_auto_approve, false) THEN 'auto_approve'::public.event_processing_mode
      ELSE 'manual_review'::public.event_processing_mode
    END;
  END IF;

  DROP TABLE IF EXISTS _bulk_input;
  CREATE TEMP TABLE _bulk_input ON COMMIT DROP AS
  WITH inputs AS (
    SELECT
      (idx - 1)::int AS ord,
      (elem->>'title')::text                    AS title,
      (elem->>'description')::text              AS description,
      (elem->>'start_datetime')::timestamptz    AS start_datetime,
      NULLIF(elem->>'end_datetime', '')::timestamptz AS end_datetime,
      (elem->>'timezone')::text                 AS timezone,
      (elem->>'venue_name')::text               AS venue_name,
      (elem->>'address')::text                  AS address,
      NULLIF(elem->>'city_id', '')::uuid        AS city_id,
      NULLIF(elem->>'source_url', '')::text     AS source_url,
      (elem->>'source_name')::text              AS source_name,
      COALESCE(elem->'images', '[]'::jsonb)     AS images,
      NULLIF(elem->>'price', '')::numeric       AS price,
      COALESCE((elem->>'is_free')::boolean, false) AS is_free,
      NULLIF(elem->>'is_outdoor', '')::boolean  AS is_outdoor,
      NULLIF(elem->>'latitude', '')::numeric    AS latitude,
      NULLIF(elem->>'longitude', '')::numeric   AS longitude
    FROM jsonb_array_elements(p_events) WITH ORDINALITY AS j(elem, idx)
  ),
  classified AS (
    SELECT
      i.*,
      su.id AS source_url_match
    FROM inputs i
    LEFT JOIN LATERAL (
      SELECT e.id FROM public.events e
      WHERE e.source_id = p_source_id
        AND e.source_url IS NOT NULL
        AND e.source_url = i.source_url
      LIMIT 1
    ) su ON i.source_url IS NOT NULL
  )
  SELECT
    c.*,
    CASE
      WHEN c.source_url_match IS NOT NULL THEN 'update'
      ELSE 'insert'
    END AS decision,
    c.source_url_match AS target_event_id
  FROM classified c;

  DROP TABLE IF EXISTS _bulk_inserted;
  CREATE TEMP TABLE _bulk_inserted ON COMMIT DROP AS
  WITH src AS (
    SELECT * FROM _bulk_input WHERE decision = 'insert'
  ),
  ins AS (
    INSERT INTO public.events (
      title, description, start_datetime, end_datetime, timezone,
      venue_name, address, city_id, latitude, longitude,
      price, is_free, is_outdoor,
      source_url, source_name, source_id,
      images, status,
      llm_review_status,
      llm_review_decision,
      llm_review_confidence,
      llm_review_reason,
      llm_review_flags,
      llm_review_provider,
      llm_review_model,
      llm_review_prompt_version,
      llm_reviewed_at,
      llm_review_error
    )
    SELECT
      s.title, s.description, s.start_datetime, s.end_datetime, s.timezone,
      s.venue_name, s.address, s.city_id, s.latitude, s.longitude,
      s.price, s.is_free, s.is_outdoor,
      s.source_url, s.source_name, p_source_id,
      s.images,
      CASE
        WHEN v_processing_mode = 'auto_approve'::public.event_processing_mode THEN 'published'
        ELSE 'draft'
      END,
      CASE
        WHEN v_processing_mode = 'llm_review'::public.event_processing_mode
          THEN 'pending'::public.llm_event_review_status
        ELSE 'not_required'::public.llm_event_review_status
      END,
      NULL,
      NULL,
      NULL,
      '{}'::text[],
      NULL,
      NULL,
      NULL,
      NULL,
      NULL
    FROM src s
    ON CONFLICT (source_id, source_url)
      WHERE source_url IS NOT NULL
      DO NOTHING
    RETURNING id, source_url
  )
  SELECT id, source_url FROM ins;

  GET DIAGNOSTICS v_imported = ROW_COUNT;

  DROP TABLE IF EXISTS _bulk_update_targets;
  CREATE TEMP TABLE _bulk_update_targets ON COMMIT DROP AS
  SELECT b.*, e.id AS event_id, e.admin_locked_fields
  FROM _bulk_input b
  JOIN public.events e
    ON e.source_id = p_source_id
   AND e.source_url IS NOT NULL
   AND e.source_url = b.source_url
  WHERE b.decision = 'update'
     OR (b.decision = 'insert' AND b.source_url IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM _bulk_inserted i WHERE i.source_url = b.source_url));

  WITH updated AS (
    UPDATE public.events e SET
      title          = CASE WHEN 'title'          = ANY(e.admin_locked_fields) THEN e.title          ELSE t.title          END,
      description    = CASE WHEN 'description'    = ANY(e.admin_locked_fields) THEN e.description    ELSE t.description    END,
      start_datetime = CASE WHEN 'start_datetime' = ANY(e.admin_locked_fields) THEN e.start_datetime ELSE t.start_datetime END,
      end_datetime   = CASE WHEN 'end_datetime'   = ANY(e.admin_locked_fields) THEN e.end_datetime   ELSE t.end_datetime   END,
      timezone       = CASE WHEN 'timezone'       = ANY(e.admin_locked_fields) THEN e.timezone       ELSE t.timezone       END,
      venue_name     = CASE WHEN 'venue_name'     = ANY(e.admin_locked_fields) THEN e.venue_name     ELSE t.venue_name     END,
      address        = CASE WHEN 'address'        = ANY(e.admin_locked_fields) THEN e.address        ELSE t.address        END,
      city_id        = CASE WHEN 'city_id'        = ANY(e.admin_locked_fields) THEN e.city_id        ELSE t.city_id        END,
      source_url     = CASE WHEN 'source_url'     = ANY(e.admin_locked_fields) THEN e.source_url     ELSE t.source_url     END,
      source_name    = CASE WHEN 'source_name'    = ANY(e.admin_locked_fields) THEN e.source_name    ELSE t.source_name    END,
      source_id      = CASE WHEN 'source_id'      = ANY(e.admin_locked_fields) THEN e.source_id      ELSE p_source_id      END,
      images         = CASE WHEN 'images'         = ANY(e.admin_locked_fields) THEN e.images         ELSE t.images         END,
      price          = CASE WHEN 'price'          = ANY(e.admin_locked_fields) THEN e.price          ELSE t.price          END,
      is_free        = CASE WHEN 'is_free'        = ANY(e.admin_locked_fields) THEN e.is_free        ELSE t.is_free        END,
      is_outdoor     = CASE WHEN 'is_outdoor'     = ANY(e.admin_locked_fields) THEN e.is_outdoor     ELSE t.is_outdoor     END,
      llm_review_status = CASE
        WHEN v_processing_mode = 'llm_review'::public.event_processing_mode
          THEN 'pending'::public.llm_event_review_status
        ELSE 'not_required'::public.llm_event_review_status
      END,
      llm_review_decision = NULL,
      llm_review_confidence = NULL,
      llm_review_reason = NULL,
      llm_review_flags = '{}'::text[],
      llm_review_provider = NULL,
      llm_review_model = NULL,
      llm_review_prompt_version = NULL,
      llm_reviewed_at = NULL,
      llm_review_error = NULL,
      updated_at     = now()
    FROM _bulk_update_targets t
    WHERE e.id = t.event_id
    RETURNING e.id
  )
  SELECT COUNT(*) INTO v_updated FROM updated;

  WITH all_imported AS (
    SELECT id FROM _bulk_inserted
    UNION ALL
    SELECT event_id AS id FROM _bulk_update_targets
  ),
  enq AS (
    INSERT INTO public.event_llm_review_queue (event_id, source_id, source_run_id, trigger_type)
    SELECT id, p_source_id, p_run_id, 'import'
    FROM all_imported
    WHERE v_processing_mode = 'llm_review'::public.event_processing_mode
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing', 'retrying')
      DO NOTHING
    RETURNING id
  ),
  tag_enq AS (
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    SELECT id, p_run_id, 'import'
    FROM all_imported
    WHERE v_processing_mode <> 'llm_review'::public.event_processing_mode
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING
    RETURNING id
  )
  SELECT
    COALESCE((SELECT COUNT(*) FROM enq), 0) + COALESCE((SELECT COUNT(*) FROM tag_enq), 0)
  INTO v_enqueued;

  RETURN jsonb_build_object(
    'imported', v_imported,
    'updated',  v_updated,
    'skipped',  v_skipped,
    'enqueued', v_enqueued
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.apply_event_llm_review_decision(
  p_queue_id bigint,
  p_event_id uuid,
  p_source_id uuid,
  p_source_run_id uuid,
  p_provider text,
  p_model text,
  p_prompt_version text,
  p_review_status public.llm_event_review_status,
  p_model_decision public.llm_event_review_decision,
  p_applied_decision public.llm_event_review_decision,
  p_confidence numeric,
  p_reason text,
  p_flags text[],
  p_suggested_category text,
  p_normalized_title text,
  p_raw_response jsonb,
  p_error_code text,
  p_error_message text,
  p_input_snapshot jsonb,
  p_processing_ms integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_event_id uuid;
  v_next_event_status text;
  v_now timestamptz := now();
BEGIN
  v_next_event_status := CASE
    WHEN p_applied_decision = 'approve'::public.llm_event_review_decision THEN 'published'
    WHEN p_applied_decision = 'reject'::public.llm_event_review_decision THEN 'rejected'
    ELSE 'draft'
  END;

  UPDATE public.events
  SET status = v_next_event_status,
      llm_review_status = p_review_status,
      llm_review_decision = p_applied_decision,
      llm_review_confidence = p_confidence,
      llm_review_reason = p_reason,
      llm_review_flags = COALESCE(p_flags, '{}'::text[]),
      llm_review_provider = p_provider,
      llm_review_model = p_model,
      llm_review_prompt_version = p_prompt_version,
      llm_reviewed_at = v_now,
      llm_review_error = p_error_message,
      updated_at = v_now
  WHERE id = p_event_id
    AND status = 'draft'
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    RETURN false;
  END IF;

  INSERT INTO public.event_llm_review_traces (
    event_id,
    queue_id,
    source_id,
    source_run_id,
    provider,
    model,
    prompt_version,
    status,
    model_decision,
    applied_decision,
    confidence,
    reason,
    flags,
    suggested_category,
    normalized_title,
    raw_response,
    error_code,
    error_message,
    input_snapshot,
    processing_ms
  )
  VALUES (
    p_event_id,
    p_queue_id,
    p_source_id,
    p_source_run_id,
    p_provider,
    p_model,
    p_prompt_version,
    p_review_status,
    p_model_decision,
    p_applied_decision,
    p_confidence,
    p_reason,
    COALESCE(p_flags, '{}'::text[]),
    p_suggested_category,
    p_normalized_title,
    p_raw_response,
    p_error_code,
    p_error_message,
    p_input_snapshot,
    p_processing_ms
  );

  IF p_applied_decision <> 'reject'::public.llm_event_review_decision THEN
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    VALUES (p_event_id, p_source_run_id, 'import')
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING;
  END IF;

  UPDATE public.event_llm_review_queue
  SET status = 'succeeded',
      finished_at = v_now,
      last_error = NULL,
      updated_at = v_now
  WHERE id = p_queue_id;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_event_llm_review_decision(
  p_queue_id bigint,
  p_event_id uuid,
  p_source_id uuid,
  p_source_run_id uuid,
  p_provider text,
  p_model text,
  p_prompt_version text,
  p_review_status public.llm_event_review_status,
  p_model_decision public.llm_event_review_decision,
  p_applied_decision public.llm_event_review_decision,
  p_confidence numeric,
  p_reason text,
  p_flags text[],
  p_suggested_category text,
  p_normalized_title text,
  p_raw_response jsonb,
  p_error_code text,
  p_error_message text,
  p_input_snapshot jsonb,
  p_processing_ms integer
)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.apply_event_llm_review_decision(
    p_queue_id,
    p_event_id,
    p_source_id,
    p_source_run_id,
    p_provider,
    p_model,
    p_prompt_version,
    p_review_status,
    p_model_decision,
    p_applied_decision,
    p_confidence,
    p_reason,
    p_flags,
    p_suggested_category,
    p_normalized_title,
    p_raw_response,
    p_error_code,
    p_error_message,
    p_input_snapshot,
    p_processing_ms
  );
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
GRANT SELECT ON public.event_llm_review_queue TO authenticated;
GRANT SELECT ON public.event_llm_review_traces TO authenticated;
GRANT SELECT ON public.event_llm_review_queue_summary TO authenticated;

REVOKE EXECUTE ON FUNCTION private.claim_event_llm_review_queue_batch(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.claim_event_llm_review_queue_batch(integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.claim_event_llm_review_queue_batch(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.claim_event_llm_review_queue_batch(integer) TO service_role;

REVOKE EXECUTE ON FUNCTION private.mark_event_llm_review_queue_row_started(bigint) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.mark_event_llm_review_queue_row_started(bigint) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mark_event_llm_review_queue_row_started(bigint) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_event_llm_review_queue_row_started(bigint) TO service_role;

REVOKE EXECUTE ON FUNCTION private.release_unstarted_event_llm_review_rows(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.release_unstarted_event_llm_review_rows(bigint[]) TO service_role;
REVOKE EXECUTE ON FUNCTION public.release_unstarted_event_llm_review_rows(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_unstarted_event_llm_review_rows(bigint[]) TO service_role;

REVOKE EXECUTE ON FUNCTION private.reap_stuck_event_llm_review_rows() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reap_stuck_event_llm_review_rows() TO service_role;
REVOKE EXECUTE ON FUNCTION public.reap_stuck_event_llm_review_rows() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.reap_stuck_event_llm_review_rows() TO service_role;

REVOKE EXECUTE ON FUNCTION public.invoke_process_event_review_queue() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.invoke_process_event_review_queue() TO service_role;

REVOKE EXECUTE ON FUNCTION private.apply_event_llm_review_decision(
  bigint, uuid, uuid, uuid, text, text, text,
  public.llm_event_review_status, public.llm_event_review_decision, public.llm_event_review_decision,
  numeric, text, text[], text, text, jsonb, text, text, jsonb, integer
) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.apply_event_llm_review_decision(
  bigint, uuid, uuid, uuid, text, text, text,
  public.llm_event_review_status, public.llm_event_review_decision, public.llm_event_review_decision,
  numeric, text, text[], text, text, jsonb, text, text, jsonb, integer
) TO service_role;
REVOKE EXECUTE ON FUNCTION public.apply_event_llm_review_decision(
  bigint, uuid, uuid, uuid, text, text, text,
  public.llm_event_review_status, public.llm_event_review_decision, public.llm_event_review_decision,
  numeric, text, text[], text, text, jsonb, text, text, jsonb, integer
) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.apply_event_llm_review_decision(
  bigint, uuid, uuid, uuid, text, text, text,
  public.llm_event_review_status, public.llm_event_review_decision, public.llm_event_review_decision,
  numeric, text, text[], text, text, jsonb, text, text, jsonb, integer
) TO service_role;

REVOKE EXECUTE ON FUNCTION private.admin_bulk_set_processing_mode(public.event_processing_mode) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION private.admin_bulk_set_processing_mode(public.event_processing_mode) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_bulk_set_processing_mode(public.event_processing_mode) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.admin_bulk_set_processing_mode(public.event_processing_mode) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_bulk_set_auto_approve(boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION private.admin_bulk_set_auto_approve(boolean) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_bulk_set_auto_approve(boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.admin_bulk_set_auto_approve(boolean) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_set_event_source_processing_mode(uuid, public.event_processing_mode) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION private.admin_set_event_source_processing_mode(uuid, public.event_processing_mode) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_set_event_source_processing_mode(uuid, public.event_processing_mode) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.admin_set_event_source_processing_mode(uuid, public.event_processing_mode) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_update_event_status(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION private.admin_update_event_status(uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_update_event_status(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.admin_update_event_status(uuid, text, text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  TO authenticated;

COMMIT;


-- ============================================================================
-- Source: 20260601008600_admin_update_source_processing_mode.sql
-- ============================================================================

-- Fix: admin_update_source silently dropped processing_mode patches.
-- The admin UI sends { processing_mode, auto_approve } when a user flips
-- a source's processing mode in the Sources page; only auto_approve was
-- being applied. The dropdown then reverted on refetch because
-- processing_mode never changed. Adds the missing CASE branch so
-- processing_mode is persisted (including a cast to the enum so invalid
-- values fail loud instead of silently no-opping).

BEGIN;

CREATE OR REPLACE FUNCTION private.admin_update_source(
  p_source_id uuid,
  p_patch jsonb
) RETURNS public.event_sources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  patch jsonb := COALESCE(p_patch, '{}'::jsonb);
  before_row public.event_sources%ROWTYPE;
  updated_row public.event_sources%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_ADMIN_REQUIRED';
  END IF;

  IF patch ? 'name' AND NULLIF(btrim(patch->>'name'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NAME_REQUIRED';
  END IF;

  IF patch ? 'url' AND NULLIF(btrim(patch->>'url'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_URL_REQUIRED';
  END IF;

  SELECT *
    INTO before_row
    FROM public.event_sources
   WHERE id = p_source_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NOT_FOUND';
  END IF;

  UPDATE public.event_sources
     SET name = CASE WHEN patch ? 'name' THEN btrim(patch->>'name') ELSE name END,
         url = CASE WHEN patch ? 'url' THEN btrim(patch->>'url') ELSE url END,
         source_type = CASE WHEN patch ? 'source_type' THEN patch->>'source_type' ELSE source_type END,
         extraction_mode = CASE WHEN patch ? 'extraction_mode' THEN (patch->>'extraction_mode')::public.source_extraction_mode ELSE extraction_mode END,
         processing_mode = CASE WHEN patch ? 'processing_mode' THEN (patch->>'processing_mode')::public.event_processing_mode ELSE processing_mode END,
         city_id = CASE
           WHEN patch ? 'city_id' AND jsonb_typeof(patch->'city_id') = 'null' THEN NULL
           WHEN patch ? 'city_id' AND NULLIF(btrim(patch->>'city_id'), '') IS NULL THEN NULL
           WHEN patch ? 'city_id' THEN (patch->>'city_id')::uuid
           ELSE city_id
         END,
         is_active = CASE WHEN patch ? 'is_active' THEN (patch->>'is_active')::boolean ELSE is_active END,
         auto_approve = CASE WHEN patch ? 'auto_approve' THEN (patch->>'auto_approve')::boolean ELSE auto_approve END,
         scrape_interval_hours = CASE WHEN patch ? 'scrape_interval_hours' THEN (patch->>'scrape_interval_hours')::integer ELSE scrape_interval_hours END,
         last_scraped_at = CASE
           WHEN patch ? 'last_scraped_at' AND jsonb_typeof(patch->'last_scraped_at') = 'null' THEN NULL
           WHEN patch ? 'last_scraped_at' THEN (patch->>'last_scraped_at')::timestamptz
           ELSE last_scraped_at
         END,
         last_status = CASE
           WHEN patch ? 'last_status' AND jsonb_typeof(patch->'last_status') = 'null' THEN NULL
           WHEN patch ? 'last_status' THEN patch->>'last_status'
           ELSE last_status
         END,
         error_count = CASE WHEN patch ? 'error_count' THEN (patch->>'error_count')::integer ELSE error_count END,
         notes = CASE
           WHEN patch ? 'notes' AND jsonb_typeof(patch->'notes') = 'null' THEN NULL
           WHEN patch ? 'notes' THEN patch->>'notes'
           ELSE notes
         END,
         date_window_days = CASE
           WHEN patch ? 'date_window_days' AND jsonb_typeof(patch->'date_window_days') = 'null' THEN NULL
           WHEN patch ? 'date_window_days' THEN (patch->>'date_window_days')::integer
           ELSE date_window_days
         END,
         updated_at = now()
   WHERE id = p_source_id
   RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'source.update',
    'event_source',
    p_source_id,
    jsonb_build_object('previous', to_jsonb(before_row), 'patch', patch)
  );

  RETURN updated_row;
END;
$$;

COMMIT;


-- ============================================================================
-- Source: 20260601008700_fix_bulk_source_updates_safe_where.sql
-- ============================================================================

BEGIN;

/*
  Supabase safe-update guard rejects table-wide UPDATEs without a WHERE clause.
  The admin bulk processing-mode RPCs intentionally target all sources, so we
  keep semantics while satisfying the guard with an explicit predicate.
*/

CREATE OR REPLACE FUNCTION private.admin_bulk_set_processing_mode(
  p_mode public.event_processing_mode
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_sources
  SET processing_mode = p_mode,
      auto_approve = (p_mode = 'auto_approve'::public.event_processing_mode),
      updated_at = now()
  WHERE id IS NOT NULL;
  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'bulk_set_processing_mode',
    'event_sources',
    jsonb_build_object('processing_mode', p_mode::text, 'affected_count', affected)
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.admin_bulk_set_auto_approve(enable boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_sources
  SET auto_approve = enable,
      processing_mode = CASE
        WHEN enable THEN 'auto_approve'::public.event_processing_mode
        ELSE 'manual_review'::public.event_processing_mode
      END,
      updated_at = now()
  WHERE id IS NOT NULL;
  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'bulk_set_auto_approve',
    'event_sources',
    jsonb_build_object('enable', enable, 'affected_count', affected)
  );
END;
$$;

COMMIT;


-- ============================================================================
-- Source: 20260601008800_enrichment_claim_city_centroid_coords.sql
-- ============================================================================

BEGIN;

/*
  Scrape now seeds event coordinates immediately (best effort geocode with city
  centroid fallback). Rows that still hold exact city-centroid coordinates are
  placeholders and should stay eligible for enrichment so precise geocodes can
  overwrite them.
*/

CREATE OR REPLACE FUNCTION private.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH enrichment_flags AS (
    SELECT
      e.*,
      -- ~0.11 m at the equator — close enough to be a centroid placeholder
      (
        (
          e.latitude IS NULL
          OR e.longitude IS NULL
          OR (
            c.latitude IS NOT NULL
            AND c.longitude IS NOT NULL
            AND e.latitude IS NOT NULL
            AND e.longitude IS NOT NULL
            AND abs(e.latitude  - c.latitude)  < 0.000001
            AND abs(e.longitude - c.longitude) < 0.000001
          )
        )
        AND NOT 'latitude'  = ANY(e.admin_locked_fields)
        AND NOT 'longitude' = ANY(e.admin_locked_fields)
      ) AS _needs_coords,
      (
        (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
        AND NOT 'images' = ANY(e.admin_locked_fields)
      ) AS _needs_images
    FROM public.events e
    LEFT JOIN public.cities c ON c.id = e.city_id
  )
  SELECT
    ef.id,
    ef.title,
    ef.description,
    ef.venue_name,
    ef.address,
    ef.city_id,
    ef.source_id,
    ef.source_url,
    ef._needs_coords  AS needs_coords,
    ef._needs_images   AS needs_images,
    ef.admin_locked_fields
  FROM enrichment_flags ef
  WHERE ef._needs_coords OR ef._needs_images
  ORDER BY ef.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

COMMIT;


-- ============================================================================
-- Source: 20260601008900_clear_llm_review_on_admin_decision.sql
-- ============================================================================

-- When an admin publishes or rejects an event the LLM review state becomes
-- stale. Clear it so the UI no longer shows a confusing "Needs review" or
-- "LLM approved" badge next to a manually-decided event.

CREATE OR REPLACE FUNCTION private.clear_llm_review_on_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('published', 'rejected')
     AND OLD.status = 'draft'
  THEN
    NEW.llm_review_status        := 'not_required';
    NEW.llm_review_decision      := NULL;
    NEW.llm_review_confidence    := NULL;
    NEW.llm_review_reason        := NULL;
    NEW.llm_review_flags         := '{}'::text[];
    NEW.llm_review_error         := NULL;
    NEW.llm_review_model         := NULL;
    NEW.llm_review_provider      := NULL;
    NEW.llm_review_prompt_version := NULL;
    NEW.llm_reviewed_at          := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clear_llm_review_on_status_change ON public.events;

CREATE TRIGGER trg_clear_llm_review_on_status_change
  BEFORE UPDATE OF status ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION private.clear_llm_review_on_status_change();

-- Fix existing published/rejected events that still carry stale LLM review data
UPDATE public.events
SET llm_review_status         = 'not_required',
    llm_review_decision       = NULL,
    llm_review_confidence     = NULL,
    llm_review_reason         = NULL,
    llm_review_flags          = '{}'::text[],
    llm_review_error          = NULL,
    llm_review_model          = NULL,
    llm_review_provider       = NULL,
    llm_review_prompt_version = NULL,
    llm_reviewed_at           = NULL,
    updated_at                = now()
WHERE status IN ('published', 'rejected')
  AND llm_review_status IS DISTINCT FROM 'not_required';


-- ============================================================================
-- Source: 20260601009000_preserve_llm_review_on_admin_decision.sql
-- ============================================================================

-- Preserve LLM review data after admin publishes/rejects so the audit trail
-- remains visible.  Only flip the status to 'not_required'; keep all other
-- fields (decision, confidence, reason, flags, provider, model, etc.) intact.

CREATE OR REPLACE FUNCTION private.clear_llm_review_on_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('published', 'rejected')
     AND OLD.status = 'draft'
  THEN
    NEW.llm_review_status := 'not_required';
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- Source: 20260601009100_event_enrichment_tags_and_scope.sql
-- ============================================================================

/*
  Image-fallback enrichment groundwork
  ------------------------------------

  Two related changes that the Unsplash image-fallback work in the
  backfill-event-enrichment edge fn needs:

    1. `private.list_events_needing_enrichment` now returns a
       `tags text[]` column carrying the event's tag slugs ordered by
       confidence DESC. The edge fn uses tags[0] as the Unsplash query
       term. Adding it to the existing RPC is backwards compatible at
       the call site (every existing caller does
       `select * from list_events_needing_enrichment(...)` so the
       extra column is automatically picked up).

    2. New `private.backfill_image_enrichment_in_scope(p_limit)` RPC
       returns the same row shape but narrows to rows where:
         (a) images is empty,
         (b) the row isn't admin-locked on `images`,
         (c) status = 'published',
         (d) either is_featured = true OR start_datetime is within
             [now, now + 30 days].
       This bounds Unsplash API spend to events users will actually see
       in the next month. The existing coords-only flow keeps using
       `list_events_needing_enrichment` so it can still fill geocodes
       on stale rows.

  Both the existing tags column extension and the new scoped RPC are
  invocable only by `service_role`; the `public.*` SECURITY INVOKER
  wrappers exist for PostgREST clients (edge fns) that talk through
  the public schema.
*/

BEGIN;

-- 1) Extend list_events_needing_enrichment with tags text[].
--
-- PG won't allow CREATE OR REPLACE to change a function's RETURNS TABLE
-- shape. Drop both the public wrapper and the private implementation
-- before re-creating with the new column. No views or indexes depend
-- on these RPCs — they're called only from edge functions over
-- PostgREST — so no CASCADE concerns.

DROP FUNCTION IF EXISTS public.list_events_needing_enrichment(int);
DROP FUNCTION IF EXISTS private.list_events_needing_enrichment(int);

CREATE OR REPLACE FUNCTION private.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH enrichment_flags AS (
    SELECT
      e.*,
      (
        (
          e.latitude IS NULL
          OR e.longitude IS NULL
          OR (
            c.latitude IS NOT NULL
            AND c.longitude IS NOT NULL
            AND e.latitude IS NOT NULL
            AND e.longitude IS NOT NULL
            AND abs(e.latitude  - c.latitude)  < 0.000001
            AND abs(e.longitude - c.longitude) < 0.000001
          )
        )
        AND NOT 'latitude'  = ANY(e.admin_locked_fields)
        AND NOT 'longitude' = ANY(e.admin_locked_fields)
      ) AS _needs_coords,
      (
        (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
        AND NOT 'images' = ANY(e.admin_locked_fields)
      ) AS _needs_images
    FROM public.events e
    LEFT JOIN public.cities c ON c.id = e.city_id
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    ef.id,
    ef.title,
    ef.description,
    ef.venue_name,
    ef.address,
    ef.city_id,
    ef.source_id,
    ef.source_url,
    ef._needs_coords  AS needs_coords,
    ef._needs_images  AS needs_images,
    ef.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[]) AS tags
  FROM enrichment_flags ef
  LEFT JOIN event_tag_slugs ets ON ets.event_id = ef.id
  WHERE ef._needs_coords OR ef._needs_images
  ORDER BY ef.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) TO service_role;

CREATE OR REPLACE FUNCTION public.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_events_needing_enrichment(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) TO service_role;

-- 2) backfill_image_enrichment_in_scope — featured OR next 30 days, images-only.

CREATE OR REPLACE FUNCTION private.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH scoped AS (
    SELECT e.*
    FROM public.events e
    WHERE e.status = 'published'
      AND (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
      AND NOT 'images' = ANY(e.admin_locked_fields)
      AND (
        e.is_featured = true
        OR (e.start_datetime BETWEEN now() AND now() + interval '30 days')
      )
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    s.id,
    s.title,
    s.description,
    s.venue_name,
    s.address,
    s.city_id,
    s.source_id,
    s.source_url,
    false                                                    AS needs_coords,
    true                                                     AS needs_images,
    s.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[])                     AS tags
  FROM scoped s
  LEFT JOIN event_tag_slugs ets ON ets.event_id = s.id
  ORDER BY s.is_featured DESC, s.start_datetime ASC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) TO service_role;

CREATE OR REPLACE FUNCTION public.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.backfill_image_enrichment_in_scope(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) TO service_role;

COMMIT;


-- ============================================================================
-- Source: 20260601009200_drop_admin_queue_tables_from_realtime_publication.sql
-- ============================================================================

-- Drop high-churn admin queue tables from supabase_realtime publication.
-- event_tag_queue alone produced ~28k WAL rows over the prior sampling
-- window with zero realtime subscribers, dominating realtime.list_changes
-- cost (63.9% of total DB time). Admin UI now polls these tables every
-- 10s instead of subscribing via postgres_changes.
ALTER PUBLICATION supabase_realtime DROP TABLE public.event_tag_queue;
ALTER PUBLICATION supabase_realtime DROP TABLE public.source_scrape_queue;
ALTER PUBLICATION supabase_realtime DROP TABLE public.source_runs;


-- ============================================================================
-- Source: 20260601009300_supabase_full_usage_hardening.sql
-- ============================================================================

-- Tighten Supabase API exposure and remove unused GraphQL surface.
--
-- This migration keeps the app's REST/PostgREST paths working while removing
-- old broad table grants that made every public object GraphQL-discoverable.

DROP EXTENSION IF EXISTS pg_graphql;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM authenticated;

-- Anonymous users only need public read paths plus invite request RPCs.
GRANT SELECT ON TABLE
  public.cities,
  public.comments,
  public.event_rating_stats,
  public.event_tag_queue,
  public.event_tag_queue_summary,
  public.event_tags,
  public.events,
  public.favorites,
  public.public_events,
  public.ratings,
  public.source_scrape_queue,
  public.source_scrape_queue_summary,
  public.tags,
  public.timezone_names,
  public.user_calendar_events
TO anon;

-- Signed-in users need normal app reads, plus admin reads guarded by RLS.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;

-- Direct browser writes still used by non-admin product flows.
GRANT INSERT, UPDATE, DELETE ON TABLE public.comments TO authenticated;
GRANT INSERT, DELETE ON TABLE public.favorites TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.ratings TO authenticated;
GRANT INSERT, DELETE ON TABLE public.user_calendar_events TO authenticated;
GRANT UPDATE (
  email,
  display_name,
  avatar_url,
  city_preference_id,
  child_name,
  child_age,
  updated_at
) ON TABLE public.user_profiles TO authenticated;

-- Direct browser writes still used by admin screens; RLS keeps these admin-only.
GRANT INSERT, UPDATE ON TABLE public.cities TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.events TO authenticated;
GRANT DELETE ON TABLE public.invite_codes TO authenticated;

-- Keep sequence access available for direct inserts without restoring broad
-- table mutation grants.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Private tables are intentionally accessed through SECURITY DEFINER RPCs.
ALTER TABLE private.cron_enabled ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.railway_cron_runs ENABLE ROW LEVEL SECURITY;

-- Advisor proof: the project should not expose pg_graphql after this migration.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_graphql') THEN
    RAISE EXCEPTION 'pg_graphql extension is still installed';
  END IF;

END
$$;


-- ============================================================================
-- Source: 20260601009400_enrichment_attempt_tracking.sql
-- ============================================================================

/*
  Enrichment attempt tracking — break the centroid livelock
  ---------------------------------------------------------

  The backfill-event-enrichment cron was stuck reprocessing the same top-12
  rows every tick. Two interacting bugs:

    1. private.list_events_needing_enrichment orders by created_at DESC,
       which never changes, so the newest 12 unfillable rows (libcal events
       whose `address` is a room label like "Meeting Room (2nd), Main
       Library") permanently occupy the top of the queue.

    2. backfill-event-enrichment/index.ts had a city-centroid fallback that
       wrote the city's lat/lng back when Nominatim returned no hit. The
       updated row still matched centroid → still flagged needs_coords →
       claimed again next tick. The other ~1080 rows in the backlog never
       got a turn.

  Fix:

    - Add events.last_enrichment_attempt_at. Bumped on every enrichment
      attempt (success OR no-op).
    - Order both claim RPCs by last_enrichment_attempt_at ASC NULLS FIRST,
      then existing tiebreaker. First pass walks the NULL backlog; from
      then on the oldest-attempted rows surface first.
    - Add private.mark_event_enrichment_attempt(p_event_id) for the
      no-op path (geocode failed, no images written) so the row still
      moves to the back of the queue.
    - update_event_enrichment now also bumps last_enrichment_attempt_at.

  The city-centroid fallback in the edge function is removed in the
  accompanying TS change (backfill-event-enrichment/index.ts).
*/

BEGIN;

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS last_enrichment_attempt_at timestamptz;

CREATE INDEX IF NOT EXISTS events_enrichment_attempt_idx
  ON public.events (last_enrichment_attempt_at NULLS FIRST, created_at DESC);

-- Drop wrappers + impl so we can change ORDER BY (PG allows CREATE OR REPLACE
-- for body changes but RETURNS TABLE shape is unchanged here so a plain
-- CREATE OR REPLACE would also work; the explicit DROP keeps the migration
-- symmetric with 20260601009100 which did need the drop).
DROP FUNCTION IF EXISTS public.list_events_needing_enrichment(int);
DROP FUNCTION IF EXISTS private.list_events_needing_enrichment(int);

CREATE OR REPLACE FUNCTION private.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH enrichment_flags AS (
    SELECT
      e.*,
      (
        (
          e.latitude IS NULL
          OR e.longitude IS NULL
          OR (
            c.latitude IS NOT NULL
            AND c.longitude IS NOT NULL
            AND e.latitude IS NOT NULL
            AND e.longitude IS NOT NULL
            AND abs(e.latitude  - c.latitude)  < 0.000001
            AND abs(e.longitude - c.longitude) < 0.000001
          )
        )
        AND NOT 'latitude'  = ANY(e.admin_locked_fields)
        AND NOT 'longitude' = ANY(e.admin_locked_fields)
      ) AS _needs_coords,
      (
        (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
        AND NOT 'images' = ANY(e.admin_locked_fields)
      ) AS _needs_images
    FROM public.events e
    LEFT JOIN public.cities c ON c.id = e.city_id
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    ef.id,
    ef.title,
    ef.description,
    ef.venue_name,
    ef.address,
    ef.city_id,
    ef.source_id,
    ef.source_url,
    ef._needs_coords  AS needs_coords,
    ef._needs_images  AS needs_images,
    ef.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[]) AS tags
  FROM enrichment_flags ef
  LEFT JOIN event_tag_slugs ets ON ets.event_id = ef.id
  WHERE ef._needs_coords OR ef._needs_images
  ORDER BY ef.last_enrichment_attempt_at ASC NULLS FIRST, ef.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) TO service_role;

CREATE OR REPLACE FUNCTION public.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_events_needing_enrichment(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) TO service_role;

-- backfill_image_enrichment_in_scope has the same livelock risk: featured
-- rows or upcoming rows whose Unsplash tag lookup keeps returning nothing
-- would otherwise re-claim every tick.
DROP FUNCTION IF EXISTS public.backfill_image_enrichment_in_scope(int);
DROP FUNCTION IF EXISTS private.backfill_image_enrichment_in_scope(int);

CREATE OR REPLACE FUNCTION private.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH scoped AS (
    SELECT e.*
    FROM public.events e
    WHERE e.status = 'published'
      AND (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
      AND NOT 'images' = ANY(e.admin_locked_fields)
      AND (
        e.is_featured = true
        OR (e.start_datetime BETWEEN now() AND now() + interval '30 days')
      )
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    s.id,
    s.title,
    s.description,
    s.venue_name,
    s.address,
    s.city_id,
    s.source_id,
    s.source_url,
    false                                                    AS needs_coords,
    true                                                     AS needs_images,
    s.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[])                     AS tags
  FROM scoped s
  LEFT JOIN event_tag_slugs ets ON ets.event_id = s.id
  ORDER BY s.last_enrichment_attempt_at ASC NULLS FIRST,
           s.is_featured DESC,
           s.start_datetime ASC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) TO service_role;

CREATE OR REPLACE FUNCTION public.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.backfill_image_enrichment_in_scope(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) TO service_role;

-- update_event_enrichment now also bumps last_enrichment_attempt_at so
-- successful writes count as an attempt and roll to the back of the queue.
CREATE OR REPLACE FUNCTION private.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.events e SET
    latitude = CASE
      WHEN 'latitude' = ANY(e.admin_locked_fields) THEN e.latitude
      WHEN p_latitude IS NULL THEN e.latitude
      ELSE p_latitude
    END,
    longitude = CASE
      WHEN 'longitude' = ANY(e.admin_locked_fields) THEN e.longitude
      WHEN p_longitude IS NULL THEN e.longitude
      ELSE p_longitude
    END,
    images = CASE
      WHEN 'images' = ANY(e.admin_locked_fields) THEN e.images
      WHEN p_images IS NULL OR jsonb_array_length(p_images) = 0 THEN e.images
      ELSE p_images
    END,
    last_enrichment_attempt_at = now(),
    updated_at = now()
  WHERE e.id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

-- Public wrapper unchanged in shape; recreate the body so the comment
-- about the attempt-timestamp side effect stays in one place.
CREATE OR REPLACE FUNCTION public.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.update_event_enrichment(p_event_id, p_latitude, p_longitude, p_images);
$$;

REVOKE EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

-- No-op attempt marker. Edge function calls this when an enrichment pass
-- produced neither coords nor images so the row still rotates out of the
-- front of the claim queue.
CREATE OR REPLACE FUNCTION private.mark_event_enrichment_attempt(p_event_id uuid)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.events
  SET last_enrichment_attempt_at = now()
  WHERE id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.mark_event_enrichment_attempt(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.mark_event_enrichment_attempt(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.mark_event_enrichment_attempt(p_event_id uuid)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.mark_event_enrichment_attempt(p_event_id);
$$;

REVOKE EXECUTE ON FUNCTION public.mark_event_enrichment_attempt(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_event_enrichment_attempt(uuid) TO service_role;

COMMIT;

