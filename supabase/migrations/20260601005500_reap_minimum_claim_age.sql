-- Fix race in tag/source queue reap: previously `started_at IS NULL` reaped
-- any claim before its worker iteration set `started_at`, so a second worker
-- invocation's reap step would reset the first worker's in-flight rows back
-- to 'pending'. The first worker's eventual `markSuccess` then races a
-- concurrent reset and intermittently throws PostgrestError that the worker
-- serialises as "[object Object]".
--
-- Fix: require the claim to be at least 5 minutes old before reaping a row
-- that hasn't reached the mark-started step. `next_attempt_at` is the claim
-- lower bound (claim filters `next_attempt_at <= now()` and does not update
-- the column), so `next_attempt_at < now() - 5 min` reliably means "claimed
-- more than 5 min ago and the worker never advanced past claim".

BEGIN;

CREATE OR REPLACE FUNCTION public.reap_stuck_tag_queue_rows()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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

CREATE OR REPLACE FUNCTION private.reap_stuck_source_scrape_queue_rows()
RETURNS integer
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
      (started_at IS NULL  AND next_attempt_at < now() - interval '5 minutes')
      OR started_at < now() - interval '15 minutes'
    );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

COMMIT;
