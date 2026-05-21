-- Durable source ingestion queue and tag-queue status cleanup.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'source_extraction_mode') THEN
    CREATE TYPE public.source_extraction_mode AS ENUM (
      'deterministic',
      'llm',
      'deterministic_then_llm'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'source_scrape_queue_status') THEN
    CREATE TYPE public.source_scrape_queue_status AS ENUM (
      'pending',
      'processing',
      'retrying',
      'succeeded',
      'dead'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.source_scrape_queue (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id uuid REFERENCES public.event_sources(id) ON DELETE SET NULL,
  source_run_id uuid REFERENCES public.source_runs(id) ON DELETE SET NULL,
  status public.source_scrape_queue_status NOT NULL DEFAULT 'pending',
  trigger_type text NOT NULL DEFAULT 'manual'
    CHECK (trigger_type IN ('manual', 'scheduled', 'bulk', 'retry')),
  attempt_count int NOT NULL DEFAULT 0,
  enqueued_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_error text,
  skip_reason text
);

ALTER TABLE public.source_scrape_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.source_scrape_queue FORCE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX IF NOT EXISTS source_scrape_queue_source_active_uniq
  ON public.source_scrape_queue (source_id)
  WHERE source_id IS NOT NULL AND status IN ('pending', 'processing', 'retrying');

CREATE INDEX IF NOT EXISTS source_scrape_queue_claimable_idx
  ON public.source_scrape_queue (next_attempt_at, id)
  WHERE status IN ('pending', 'retrying');

CREATE INDEX IF NOT EXISTS source_scrape_queue_status_idx
  ON public.source_scrape_queue (status, enqueued_at DESC);

DROP POLICY IF EXISTS "Admins can read source scrape queue" ON public.source_scrape_queue;
CREATE POLICY "Admins can read source scrape queue"
  ON public.source_scrape_queue FOR SELECT TO authenticated
  USING (private.is_admin());

ALTER TABLE public.event_sources
  ADD COLUMN IF NOT EXISTS extraction_mode public.source_extraction_mode NOT NULL DEFAULT 'deterministic';

CREATE TABLE IF NOT EXISTS public.source_extraction_traces (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_queue_id bigint REFERENCES public.source_scrape_queue(id) ON DELETE SET NULL,
  source_run_id uuid REFERENCES public.source_runs(id) ON DELETE SET NULL,
  source_id uuid REFERENCES public.event_sources(id) ON DELETE SET NULL,
  extraction_mode public.source_extraction_mode NOT NULL,
  extractor text NOT NULL CHECK (extractor IN ('deterministic', 'llm')),
  provider text,
  model text,
  status text NOT NULL CHECK (status IN ('success', 'fallback', 'error')),
  input_bytes int,
  parsed_event_count int NOT NULL DEFAULT 0,
  fallback_reason text,
  latency_ms int,
  reasoning_summary text,
  error text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.source_extraction_traces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.source_extraction_traces FORCE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS source_extraction_traces_source_run_idx
  ON public.source_extraction_traces(source_run_id, created_at DESC)
  WHERE source_run_id IS NOT NULL;

DROP POLICY IF EXISTS "Admins can read source extraction traces" ON public.source_extraction_traces;
CREATE POLICY "Admins can read source extraction traces"
  ON public.source_extraction_traces FOR SELECT TO authenticated
  USING (private.is_admin());

CREATE OR REPLACE FUNCTION public.claim_source_scrape_queue_batch(p_limit int DEFAULT 5)
RETURNS SETOF public.source_scrape_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  UPDATE public.source_scrape_queue q
  SET status = 'processing',
      started_at = NULL
  WHERE q.id IN (
    SELECT i.id
    FROM public.source_scrape_queue i
    WHERE i.status IN ('pending', 'retrying')
      AND i.next_attempt_at <= now()
    ORDER BY i.next_attempt_at, i.id
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(p_limit, 25))
  )
  RETURNING *;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_source_scrape_queue_started(p_queue_id bigint)
RETURNS public.source_scrape_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.source_scrape_queue;
BEGIN
  UPDATE public.source_scrape_queue
  SET started_at = now(),
      attempt_count = attempt_count + 1
  WHERE id = p_queue_id
    AND status = 'processing'
    AND started_at IS NULL
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_unstarted_source_scrape_queue_rows(p_claimed_ids bigint[])
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.source_scrape_queue
  SET status = 'pending',
      started_at = NULL
  WHERE id = ANY(p_claimed_ids)
    AND status = 'processing'
    AND started_at IS NULL
    AND source_run_id IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.reap_stuck_source_scrape_queue_rows()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.source_scrape_queue
  SET status = 'retrying',
      started_at = NULL,
      source_run_id = CASE WHEN started_at IS NULL THEN NULL ELSE source_run_id END,
      last_error = coalesce(last_error, 'reaped after stuck in processing')
  WHERE status = 'processing'
    AND (
      started_at IS NULL
      OR started_at < now() - interval '15 minutes'
    );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_source_scrape_queue_skipped(
  p_queue_id bigint,
  p_skip_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.source_scrape_queue
  SET status = 'succeeded',
      finished_at = now(),
      skip_reason = left(coalesce(p_skip_reason, 'source skipped'), 1000),
      last_error = NULL
  WHERE id = p_queue_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.source_scrape_queue_schedule_retry(
  p_queue_id bigint,
  p_attempt_count int,
  p_error text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_next timestamptz;
BEGIN
  IF p_attempt_count >= 4 THEN
    UPDATE public.source_scrape_queue
    SET status = 'dead',
        finished_at = now(),
        last_error = left(coalesce(p_error, ''), 1000)
    WHERE id = p_queue_id;
    RETURN;
  END IF;

  v_next := CASE
    WHEN p_attempt_count = 1 THEN now() + interval '5 minutes'
    WHEN p_attempt_count = 2 THEN now() + interval '15 minutes'
    ELSE now() + interval '60 minutes'
  END;

  UPDATE public.source_scrape_queue
  SET status = 'pending',
      started_at = NULL,
      next_attempt_at = v_next,
      last_error = left(coalesce(p_error, ''), 1000)
  WHERE id = p_queue_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.run_due_source_scrapes()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_enqueued int := 0;
BEGIN
  INSERT INTO public.source_scrape_queue (source_id, trigger_type)
  SELECT s.id, 'scheduled'
  FROM public.event_sources s
  WHERE s.is_active = true
    AND (
      s.last_scraped_at IS NULL
      OR s.last_scraped_at + make_interval(hours => s.scrape_interval_hours) <= now()
    )
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_enqueued = ROW_COUNT;
  RETURN jsonb_build_object('enqueued', v_enqueued);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_run_due_scrapes()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN public.run_due_source_scrapes();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_retry_source_scrape_queue(p_queue_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source_id uuid;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT source_id INTO v_source_id
  FROM public.source_scrape_queue
  WHERE id = p_queue_id
    AND status = 'dead';

  IF v_source_id IS NULL THEN
    RETURN false;
  END IF;

  INSERT INTO public.source_scrape_queue (source_id, trigger_type)
  VALUES (v_source_id, 'retry')
  ON CONFLICT DO NOTHING;

  RETURN EXISTS (
    SELECT 1 FROM public.source_scrape_queue
    WHERE source_id = v_source_id
      AND status IN ('pending', 'processing', 'retrying')
  );
END;
$$;

CREATE OR REPLACE VIEW public.source_scrape_queue_summary
WITH (security_invoker = true) AS
SELECT
  status,
  count(*)::int AS row_count,
  min(enqueued_at) AS oldest_enqueued_at,
  min(started_at) FILTER (WHERE status = 'processing') AS oldest_processing_started_at,
  max(finished_at) AS newest_finished_at,
  max(finished_at) FILTER (WHERE status = 'dead') AS last_dead_letter_at,
  avg(attempt_count)::numeric(10,2) AS avg_attempts
FROM public.source_scrape_queue
GROUP BY status;

GRANT SELECT ON public.source_scrape_queue_summary TO authenticated;
GRANT SELECT ON public.source_extraction_traces TO authenticated;

REVOKE ALL ON FUNCTION public.claim_source_scrape_queue_batch(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_source_scrape_queue_started(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_unstarted_source_scrape_queue_rows(bigint[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reap_stuck_source_scrape_queue_rows() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_source_scrape_queue_skipped(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.source_scrape_queue_schedule_retry(bigint, int, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.run_due_source_scrapes() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_run_due_scrapes() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_retry_source_scrape_queue(bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.claim_source_scrape_queue_batch(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_source_scrape_queue_started(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_unstarted_source_scrape_queue_rows(bigint[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.reap_stuck_source_scrape_queue_rows() TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_source_scrape_queue_skipped(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.source_scrape_queue_schedule_retry(bigint, int, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.run_due_source_scrapes() TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_run_due_scrapes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_retry_source_scrape_queue(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.release_unstarted_tag_queue_rows(p_claimed_ids bigint[])
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.event_tag_queue
  SET status = 'pending',
      started_at = NULL
  WHERE id = ANY(p_claimed_ids)
    AND status = 'processing'
    AND started_at IS NULL
    AND finished_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_tag_queue_batch(p_limit int DEFAULT 20)
RETURNS SETOF public.event_tag_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  UPDATE public.event_tag_queue q SET
    status = 'processing',
    started_at = NULL
  WHERE q.id IN (
    SELECT inner_q.id
    FROM public.event_tag_queue inner_q
    WHERE inner_q.status = 'pending'
      AND inner_q.next_attempt_at <= now()
    ORDER BY inner_q.next_attempt_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(p_limit, 100))
  )
  RETURNING *;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_tag_queue_row_started(p_queue_id bigint)
RETURNS public.event_tag_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.event_tag_queue;
BEGIN
  UPDATE public.event_tag_queue
  SET started_at = now(),
      attempt_count = attempt_count + 1
  WHERE id = p_queue_id
    AND status = 'processing'
    AND started_at IS NULL
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.release_unstarted_tag_queue_rows(bigint[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_tag_queue_batch(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_tag_queue_row_started(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.release_unstarted_tag_queue_rows(bigint[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_tag_queue_batch(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_tag_queue_row_started(bigint) TO service_role;

UPDATE public.event_tag_queue
SET status = 'succeeded'
WHERE status = 'failed'
  AND finished_at IS NOT NULL
  AND last_error IS NULL;
