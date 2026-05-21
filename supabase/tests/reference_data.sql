/*
  # Consolidated migration reference data smoke test

  Verifies the production-reset baseline keeps only the intended source set.

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/reference_data.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

DO $$
DECLARE
  brec_ok boolean;
  ebrpl_exists boolean;
  macaroni_ok boolean;
  cleanup_rpc_exists boolean;
  maintenance_rpc_exists boolean;
  railway_jobs_rpc_exists boolean;
  railway_history_rpc_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.event_sources
    WHERE name = 'BREC Parks'
      AND url = 'https://www.brec.org/calendar'
      AND source_type = 'brec'
  ) INTO brec_ok;

  IF NOT brec_ok THEN
    RAISE EXCEPTION 'REFERENCE_DATA_FAIL: BREC source is missing or not using source_type=brec';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.event_sources
    WHERE name = 'East Baton Rouge Parish Library'
       OR url = 'https://ebrpl.libcal.com/rss.php'
  ) INTO ebrpl_exists;

  IF ebrpl_exists THEN
    RAISE EXCEPTION 'REFERENCE_DATA_FAIL: EBRPL LibCal source should not be present in reset baseline';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.event_sources
    WHERE name = 'Macaroni Kid Lafayette'
      AND url = 'https://lafayettela.macaronikid.com/events'
      AND source_type = 'macaronikid'
      AND date_window_days = 90
  ) INTO macaroni_ok;

  IF NOT macaroni_ok THEN
    RAISE EXCEPTION 'REFERENCE_DATA_FAIL: Macaroni Kid Lafayette source is missing or incomplete';
  END IF;

  SELECT to_regprocedure('public.run_cleanup_stale_runs()') IS NOT NULL
    INTO cleanup_rpc_exists;
  SELECT to_regprocedure('public.run_daily_maintenance()') IS NOT NULL
    INTO maintenance_rpc_exists;
  SELECT to_regprocedure('public.admin_list_railway_cron_jobs()') IS NOT NULL
    INTO railway_jobs_rpc_exists;
  SELECT to_regprocedure('public.admin_railway_cron_run_history(text, integer)') IS NOT NULL
    INTO railway_history_rpc_exists;

  IF NOT cleanup_rpc_exists THEN
    RAISE EXCEPTION 'REFERENCE_DATA_FAIL: run_cleanup_stale_runs RPC is missing';
  END IF;
  IF NOT maintenance_rpc_exists THEN
    RAISE EXCEPTION 'REFERENCE_DATA_FAIL: run_daily_maintenance RPC is missing';
  END IF;
  IF NOT railway_jobs_rpc_exists THEN
    RAISE EXCEPTION 'REFERENCE_DATA_FAIL: admin_list_railway_cron_jobs RPC is missing';
  END IF;
  IF NOT railway_history_rpc_exists THEN
    RAISE EXCEPTION 'REFERENCE_DATA_FAIL: admin_railway_cron_run_history RPC is missing';
  END IF;

  RAISE NOTICE 'REFERENCE_DATA_OK';
END $$;
