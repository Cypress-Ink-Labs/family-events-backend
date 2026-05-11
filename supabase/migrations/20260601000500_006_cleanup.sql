/*
  # Stale source run cleanup

  Marks source_runs that have been stuck in 'running' for more than 15 minutes
  as 'error'. This handles edge function crashes and Supabase execution timeouts
  that prevent the function from writing a final status.

  Also updates the parent event_source.last_status to 'error' so the admin
  sources page reflects the failure immediately.
*/

CREATE OR REPLACE FUNCTION private.cleanup_stale_source_runs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.source_runs
  SET
    status      = 'error',
    completed_at = now(),
    error_log   = 'Run timed out — edge function did not complete within 15 minutes'
  WHERE status = 'running'
    AND started_at < now() - interval '15 minutes';

  -- Propagate to event_sources so the source card shows 'error' not 'pending'
  UPDATE public.event_sources es
  SET last_status = 'error'
  FROM public.source_runs sr
  WHERE sr.source_id = es.id
    AND sr.status = 'error'
    AND sr.error_log = 'Run timed out — edge function did not complete within 15 minutes'
    AND es.last_status = 'running';
END;
$$;

-- Schedule cleanup every 15 minutes
SELECT cron.schedule(
  'cleanup-stale-source-runs',
  '*/15 * * * *',
  $$ SELECT private.cleanup_stale_source_runs(); $$
);
