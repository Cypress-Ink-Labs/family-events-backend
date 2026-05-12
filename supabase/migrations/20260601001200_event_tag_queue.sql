-- Phase 4: durable queue for tag-event fanout
-- ----------------------------------------------------------------
-- Decouples scrape-source latency from OpenAI latency. Previously,
-- scrape-source called tag-event synchronously per-event inside its
-- import loop; a real feed of N events meant N×OpenAI roundtrips
-- inline, which routinely exceeded the 60s edge timeout and left
-- source_runs stuck mid-run.
--
-- New model: scrape-source INSERTs one row per imported event into
-- event_tag_queue and returns immediately. A separate process-tag-queue
-- edge function, scheduled by pg_cron every minute, claims a batch via
-- claim_tag_queue_batch (SELECT ... FOR UPDATE SKIP LOCKED), drains it,
-- and routes failures back to 'pending' with exponential backoff or to
-- 'dead' after MAX_ATTEMPTS.

BEGIN;

-- =============================================
-- Status enum
-- =============================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'event_tag_queue_status') THEN
    CREATE TYPE public.event_tag_queue_status AS ENUM (
      'pending', 'processing', 'failed', 'dead'
    );
  END IF;
END $$;

-- =============================================
-- Queue table
-- =============================================
CREATE TABLE IF NOT EXISTS public.event_tag_queue (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id        uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  source_run_id   uuid REFERENCES public.source_runs(id) ON DELETE SET NULL,
  trigger_type    text NOT NULL DEFAULT 'import'
                    CHECK (trigger_type IN ('import', 'reclassify', 'manual-review')),
  enqueued_at     timestamptz NOT NULL DEFAULT now(),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  started_at      timestamptz,
  finished_at     timestamptz,
  attempt_count   int NOT NULL DEFAULT 0,
  last_error      text,
  status          public.event_tag_queue_status NOT NULL DEFAULT 'pending'
);

ALTER TABLE public.event_tag_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_tag_queue FORCE ROW LEVEL SECURITY;

-- Claim index: pending rows whose backoff window has elapsed, ordered by age.
CREATE INDEX IF NOT EXISTS event_tag_queue_claimable_idx
  ON public.event_tag_queue (next_attempt_at)
  WHERE status = 'pending';

-- Prevent two active rows for the same event. Dead/failed rows accumulate
-- as audit trail and don't block re-enqueuing after a manual retry.
CREATE UNIQUE INDEX IF NOT EXISTS event_tag_queue_event_active_uniq
  ON public.event_tag_queue (event_id)
  WHERE status IN ('pending', 'processing');

-- Observability index: filter by status (for dashboard counts).
CREATE INDEX IF NOT EXISTS event_tag_queue_status_idx
  ON public.event_tag_queue (status, enqueued_at DESC);

COMMENT ON TABLE public.event_tag_queue IS
  'Durable queue for tag-event fanout. Workers claim rows via
   public.claim_tag_queue_batch (SKIP LOCKED); failures route to ''pending''
   with exponential backoff until attempt_count reaches MAX_ATTEMPTS, then
   route to ''dead'' for admin review.';

-- =============================================
-- RLS: admins see everything (observability). Writes are service-role only.
-- =============================================
DROP POLICY IF EXISTS "Admins can read tag queue" ON public.event_tag_queue;
CREATE POLICY "Admins can read tag queue"
  ON public.event_tag_queue FOR SELECT TO authenticated
  USING (private.is_admin());

-- =============================================
-- Claim RPC: atomic batch claim using SKIP LOCKED.
-- Increments attempt_count immediately so the worker can use it for
-- retry/dead-letter decisions without a second round-trip.
-- =============================================
CREATE OR REPLACE FUNCTION public.claim_tag_queue_batch(p_limit int DEFAULT 20)
RETURNS SETOF public.event_tag_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  UPDATE public.event_tag_queue q SET
    status        = 'processing',
    started_at    = now(),
    attempt_count = q.attempt_count + 1
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

REVOKE ALL ON FUNCTION public.claim_tag_queue_batch(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_tag_queue_batch(int) TO postgres, service_role;

COMMENT ON FUNCTION public.claim_tag_queue_batch(int) IS
  'Claim up to p_limit (1..100, default 20) pending queue rows whose
   next_attempt_at has elapsed. SKIP LOCKED makes this safe under
   concurrent workers.';

-- =============================================
-- Stuck-row reaper: rows that have been ''processing'' for over 5 minutes
-- are presumed crashed and pushed back to ''pending'' so they can be
-- re-claimed. Without this, a worker that dies mid-loop leaks rows
-- forever.
-- =============================================
CREATE OR REPLACE FUNCTION public.reap_stuck_tag_queue_rows()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_reaped int;
BEGIN
  UPDATE public.event_tag_queue
  SET status     = 'pending',
      started_at = NULL,
      last_error = coalesce(last_error, 'reaped after stuck in processing')
  WHERE status = 'processing'
    AND started_at < now() - interval '5 minutes';
  GET DIAGNOSTICS v_reaped = ROW_COUNT;
  RETURN v_reaped;
END;
$$;

REVOKE ALL ON FUNCTION public.reap_stuck_tag_queue_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reap_stuck_tag_queue_rows() TO postgres, service_role;

-- =============================================
-- invoke_process_tag_queue: pg_cron entrypoint. Mirrors invoke_scrape_source
-- (vault first, GUC fallback) and POSTs to the worker function.
-- =============================================
CREATE OR REPLACE FUNCTION public.invoke_process_tag_queue()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
  v_reaped        int;
BEGIN
  v_supabase_url := current_setting('app.settings.supabase_url', true);

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping process-tag-queue: missing supabase_url or service_role_key';
    RETURN;
  END IF;

  -- Reap stuck rows BEFORE invoking the worker so newly-pending rows are
  -- visible to the same pass.
  v_reaped := public.reap_stuck_tag_queue_rows();
  IF v_reaped > 0 THEN
    RAISE NOTICE 'reaped % stuck tag-queue rows', v_reaped;
  END IF;

  PERFORM net.http_post(
    url     := v_supabase_url || '/functions/v1/process-tag-queue',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body    := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invoke_process_tag_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invoke_process_tag_queue() TO postgres, service_role;

-- =============================================
-- Schedule the worker every minute.
-- =============================================
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('process-tag-queue');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Unexpected error unscheduling process-tag-queue: %', SQLERRM;
  END;
  PERFORM cron.schedule(
    'process-tag-queue',
    '* * * * *',
    $sql$SELECT public.invoke_process_tag_queue();$sql$
  );
END $$;

-- =============================================
-- Observability view for admin UI / Grafana.
-- security_invoker=true so private.is_admin() RLS on the underlying table
-- governs access.
-- =============================================
CREATE OR REPLACE VIEW public.event_tag_queue_summary
WITH (security_invoker = true) AS
SELECT
  status,
  count(*)::int                                     AS row_count,
  min(enqueued_at)                                  AS oldest_enqueued_at,
  max(enqueued_at)                                  AS newest_enqueued_at,
  max(finished_at) FILTER (WHERE status = 'dead')   AS last_dead_letter_at,
  avg(attempt_count) FILTER (WHERE status <> 'pending')::numeric(10,2) AS avg_attempts
FROM public.event_tag_queue
GROUP BY status;

GRANT SELECT ON public.event_tag_queue_summary TO authenticated;

-- =============================================
-- Admin retry RPC: re-enqueue a dead/failed row. Idempotent: if an active
-- row already exists for the event, no new row is created.
-- =============================================
CREATE OR REPLACE FUNCTION public.admin_retry_tag_queue(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.event_tag_queue (event_id, trigger_type)
  VALUES (p_event_id, 'manual-review')
  ON CONFLICT DO NOTHING;  -- partial-unique index handles dedup

  -- Did we add a new active row? Either way, return whether at least one is now active.
  RETURN EXISTS (
    SELECT 1 FROM public.event_tag_queue
    WHERE event_id = p_event_id AND status IN ('pending','processing')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_retry_tag_queue(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_retry_tag_queue(uuid) TO authenticated;

-- =============================================
-- Pruning: dead rows older than 30 days, completed rows older than 7 days.
-- =============================================
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('event-tag-queue-prune-daily');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Unexpected error unscheduling event-tag-queue-prune-daily: %', SQLERRM;
  END;
  PERFORM cron.schedule(
    'event-tag-queue-prune-daily',
    '15 3 * * *',
    $sql$
      DELETE FROM public.event_tag_queue
      WHERE (status = 'dead'   AND finished_at < now() - interval '30 days')
         OR (status = 'failed' AND finished_at < now() - interval '7 days');
    $sql$
  );
END $$;

COMMIT;
