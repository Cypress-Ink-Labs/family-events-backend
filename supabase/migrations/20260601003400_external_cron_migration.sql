-- Phase: move pg_cron prune jobs to external Railway cron.
--
-- pg_cron on Supabase Cloud has been unreliable for this project — jobs marked
-- active fire sporadically (or not at all), and cron.job_run_details is empty
-- for several jobs the admin UI surfaces as "Never run". The HTTP-invoking
-- jobs (scrape-due-sources-hourly and process-tag-queue) are already served by
-- Railway cron services hitting Supabase edge functions. This migration
-- consolidates the remaining SQL-only prune jobs behind a single RPC that
-- the new cron-db-maintenance Railway service can invoke daily.

CREATE OR REPLACE FUNCTION public.run_daily_maintenance()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_event_tag_pruned     int;
  v_invite_request_pruned int;
  v_invite_redemption_pruned int;
  v_rec_pruned           int;
BEGIN
  DELETE FROM public.event_tag_queue
  WHERE (status = 'dead'   AND finished_at < now() - interval '30 days')
     OR (status = 'failed' AND finished_at < now() - interval '7 days');
  GET DIAGNOSTICS v_event_tag_pruned = ROW_COUNT;

  DELETE FROM public.invite_request_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_request_pruned = ROW_COUNT;

  DELETE FROM public.invite_redemption_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_redemption_pruned = ROW_COUNT;

  DELETE FROM public.recommendation_signals
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_rec_pruned = ROW_COUNT;

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',          v_event_tag_pruned,
    'invite_request_attempts_pruned',  v_invite_request_pruned,
    'invite_redemption_attempts_pruned', v_invite_redemption_pruned,
    'recommendation_signals_pruned',   v_rec_pruned,
    'ran_at',                          now()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.run_daily_maintenance() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.run_daily_maintenance() TO postgres, service_role;

COMMENT ON FUNCTION public.run_daily_maintenance() IS
  'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals. Invoked by the cron-db-maintenance Railway service via the db-maintenance edge function.';

-- Unschedule the pg_cron jobs now served by Railway cron services.
-- Wrapped per job so missing jobs in older environments do not break replay.
DO $$
DECLARE
  jobname text;
BEGIN
  FOREACH jobname IN ARRAY ARRAY[
    'event-tag-queue-prune-daily',
    'recommendation-signals-prune-daily',
    'invite-request-attempts-prune-daily',
    'invite-attempts-prune-daily',
    'scrape-due-sources-hourly',
    'process-tag-queue'
  ] LOOP
    BEGIN
      PERFORM cron.unschedule(jobname);
    EXCEPTION
      WHEN undefined_object THEN NULL;
      WHEN OTHERS THEN
        RAISE WARNING 'Skipping unschedule of %: %', jobname, SQLERRM;
    END;
  END LOOP;
END
$$;
