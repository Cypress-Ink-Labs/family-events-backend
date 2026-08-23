-- Rollback: 20260823000000_fix_queue_reap_claim_staleness.sql
--
-- Restore previous function definitions and drop claimed_at column.

-- Restore claim_tag_queue_batch to previous version (no claimed_at stamping)
CREATE OR REPLACE FUNCTION private.claim_tag_queue_batch(p_limit integer DEFAULT 20)
RETURNS SETOF public.event_tag_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
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

COMMENT ON FUNCTION private.claim_tag_queue_batch(p_limit integer) IS 'Claim up to p_limit (1..100, default 20) pending queue rows whose
   next_attempt_at has elapsed. SKIP LOCKED makes this safe under
   concurrent workers.';

-- Restore reap_stuck_tag_queue_rows to previous version (use next_attempt_at, not claimed_at)
CREATE OR REPLACE FUNCTION private.reap_stuck_tag_queue_rows()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.event_tag_queue
  SET status = 'pending',
      started_at = NULL,
      last_error = coalesce(last_error, 'reaped after stuck in processing')
  WHERE status = 'processing'
    AND (
      (started_at IS NULL  AND next_attempt_at < now() - interval '5 minutes')
      OR started_at < now() - interval '15 minutes'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Restore reap_stuck_event_llm_review_rows to previous version (use next_attempt_at, not updated_at)
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

-- Re-grant execute permissions (matching existing pattern)
REVOKE EXECUTE ON FUNCTION private.claim_tag_queue_batch(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.claim_tag_queue_batch(integer) TO service_role;

REVOKE EXECUTE ON FUNCTION private.reap_stuck_tag_queue_rows() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reap_stuck_tag_queue_rows() TO service_role;

REVOKE EXECUTE ON FUNCTION private.reap_stuck_event_llm_review_rows() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reap_stuck_event_llm_review_rows() TO service_role;

-- Drop the claimed_at column
ALTER TABLE public.event_tag_queue DROP COLUMN IF EXISTS claimed_at;
