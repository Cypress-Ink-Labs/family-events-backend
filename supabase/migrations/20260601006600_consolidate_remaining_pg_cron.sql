/*
  # Finish migrating SQL-only crons off pg_cron

  Phase 2 of the migration started in 20260601003400_external_cron_migration.sql.
  That migration moved the prune jobs and scrape sweep to Railway-driven edge
  functions but left three pg_cron entries behind:

    - process-tag-queue        */15 * * * *
    - cleanup-stale-source-runs */30 * * * *
    - refresh-timezone-names   17 3 * * 0

  process-tag-queue is already double-covered by the cron-tag-queue Railway
  service. cleanup-stale-source-runs and refresh-timezone-names had no Railway
  equivalent. pg_cron's BGWorker on Supabase Cloud has been firing the old
  unscheduled jobids (2, 3) under stale schedules while the current cron.job
  rows (10, 13, 14) never fire — admin UI shows "Never run" for all three even
  though work is happening (against the wrong RPCs).

  This migration:

    1. Adds public.run_cleanup_stale_runs() SECURITY INVOKER wrapper around
       private.cleanup_stale_source_runs() so a new Railway cron service can
       hit it via service_role.
    2. Extends public.run_daily_maintenance() to also refresh the timezone
       names materialized view. Weekly → daily is fine: REFRESH MATERIALIZED
       VIEW CONCURRENTLY is idempotent + cheap and the IANA tz database
       updates ~quarterly.
    3. Unschedules the three remaining pg_cron jobs.

  After this migration the admin Scheduled Jobs page shows only Railway
  services. cron-cleanup-stale (added separately under apps/) drives the
  every-30-min sweep.
*/

BEGIN;

-- =============================================
-- 1. Wrap private.cleanup_stale_source_runs
--    so service_role can call it through PostgREST.
-- =============================================

-- The private body already exists from 20260601000500_006_cleanup.sql with
-- SECURITY DEFINER. Grant EXECUTE so the SECURITY INVOKER wrapper can reach
-- it. service_role already holds USAGE on schema private from migration
-- 20260601005600.
REVOKE EXECUTE ON FUNCTION private.cleanup_stale_source_runs() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.cleanup_stale_source_runs() TO service_role;

CREATE OR REPLACE FUNCTION public.run_cleanup_stale_runs()
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.cleanup_stale_source_runs();
$$;

REVOKE EXECUTE ON FUNCTION public.run_cleanup_stale_runs() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.run_cleanup_stale_runs() TO service_role;

COMMENT ON FUNCTION public.run_cleanup_stale_runs() IS
  'Reaps source_runs stuck in ''running'' >15 min and propagates to event_sources. Invoked by the cron-cleanup-stale Railway service via the cleanup-stale-runs edge function every 30 min. Replaces the pg_cron job of the same cadence.';

-- =============================================
-- 2. Extend run_daily_maintenance with timezone refresh
-- =============================================
-- REFRESH MATERIALIZED VIEW CONCURRENTLY on private.timezone_names_cache is
-- idempotent and ~200ms; folding it into the daily Railway sweep beats
-- maintaining a separate weekly cron entry.

CREATE OR REPLACE FUNCTION public.run_daily_maintenance()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_event_tag_pruned         int;
  v_invite_request_pruned    int;
  v_invite_redemption_pruned int;
  v_rec_pruned               int;
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

  -- Refresh the timezone names materialized view cache. Cheap + idempotent.
  -- Previously scheduled weekly via pg_cron; folded here to drop the
  -- separate cron entry.
  PERFORM private.refresh_timezone_names();

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',            v_event_tag_pruned,
    'invite_request_attempts_pruned',    v_invite_request_pruned,
    'invite_redemption_attempts_pruned', v_invite_redemption_pruned,
    'recommendation_signals_pruned',     v_rec_pruned,
    'timezone_names_refreshed',          true,
    'ran_at',                            now()
  );
END;
$$;

COMMENT ON FUNCTION public.run_daily_maintenance() IS
  'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals. Also refreshes private.timezone_names_cache (folded in from the unscheduled refresh-timezone-names pg_cron job). Invoked by cron-db-maintenance Railway service via the db-maintenance edge function.';

-- =============================================
-- 3. Unschedule the remaining pg_cron jobs
-- =============================================
-- Wrapped per-job so missing entries in older environments do not break
-- replay. The BGWorker on Supabase Cloud may keep firing stale jobids even
-- after this — that is a platform-level issue documented in migration
-- 20260601003400 — but cron.job will be clean and the admin UI will stop
-- surfacing these rows.
DO $$
DECLARE
  jobname text;
BEGIN
  FOREACH jobname IN ARRAY ARRAY[
    'process-tag-queue',
    'cleanup-stale-source-runs',
    'refresh-timezone-names'
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

COMMIT;
