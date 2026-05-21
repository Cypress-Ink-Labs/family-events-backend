-- Performance wins from slow-query review (2026-05-21).
--
-- Top offenders in pg_stat_statements:
--   1. SELECT name FROM pg_timezone_names — 23% of total time, 0% cache hit.
--      Solved by caching to a materialized view + weekly refresh.
--   2. plan_events_for_user candidate filter does
--        (start_datetime AT TIME ZONE timezone)::date = p_date
--      which defeats every existing index. Add an expression partial index
--      restricted to status='published' (the only branch the function reads).
--   3. cleanup_stale_source_runs cron fires every 15 min for a recovery-only
--      job. Drop to every 30 min — failures are surfaced within one cron tick
--      either way and writes are idempotent.

BEGIN;

-- =============================================
-- 1. Materialized cache for pg_timezone_names
-- =============================================
-- pg_timezone_names re-reads the tzdata files on every call (≈440ms mean per
-- hit on hosted Postgres). Frontend timezone pickers can read this MV
-- instead. Refreshed weekly because the IANA tz database updates roughly
-- quarterly and a stale row never breaks correctness.
CREATE MATERIALIZED VIEW IF NOT EXISTS public.timezone_names AS
  SELECT name
  FROM pg_timezone_names
  ORDER BY name;

CREATE UNIQUE INDEX IF NOT EXISTS timezone_names_name_uidx
  ON public.timezone_names (name);

COMMENT ON MATERIALIZED VIEW public.timezone_names IS
  'Cached snapshot of pg_timezone_names. Refreshed weekly by the
   refresh-timezone-names cron. Read by frontend tz pickers to avoid the
   ~440ms cost of touching pg_timezone_names on every dropdown render.';

GRANT SELECT ON public.timezone_names TO anon, authenticated, service_role;

-- Refresh routine. CONCURRENTLY needs the unique index above so dropdowns
-- never see an empty MV mid-refresh.
CREATE OR REPLACE FUNCTION private.refresh_timezone_names()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.timezone_names;
END;
$$;

REVOKE ALL ON FUNCTION private.refresh_timezone_names() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.refresh_timezone_names()
  TO postgres, service_role;

-- Weekly refresh. Sunday 03:17 UTC sits outside the scrape/tag-queue burst
-- windows.
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('refresh-timezone-names');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Skipping unschedule of refresh-timezone-names: %', SQLERRM;
  END;

  PERFORM cron.schedule(
    'refresh-timezone-names',
    '17 3 * * 0',
    $sql$SELECT private.refresh_timezone_names();$sql$
  );
END
$$;

-- =============================================
-- 2. Expression index for plan_events_for_user
-- =============================================
-- The candidate_events CTE in plan_events_for_user filters
--   WHERE e.status = 'published'
--     AND (e.start_datetime AT TIME ZONE e.timezone)::date = p_date
-- The TZ conversion blocks the existing (status, start_datetime) index from
-- pruning by day, so every call seq-scans every published event. A partial
-- expression index lets the planner do an index-only seek to the day bucket.
CREATE INDEX IF NOT EXISTS events_local_date_published_idx
  ON public.events (((start_datetime AT TIME ZONE timezone)::date))
  WHERE status = 'published';

COMMENT ON INDEX public.events_local_date_published_idx IS
  'Supports plan_events_for_user candidate_events filter on
   (start_datetime AT TIME ZONE timezone)::date for published events.
   Partial keeps the index small — drafts/archived rows are never read by
   the planner RPC.';

-- =============================================
-- 3. Throttle cleanup_stale_source_runs cron
-- =============================================
-- cleanup_stale_source_runs reaps source_runs stuck in 'running' for >15
-- minutes. Running it every 15 min only saves up to 15 min of latency on
-- surfacing the failure to the admin sources page; running every 30 min is
-- the same SLA in practice. The function is idempotent so doubling the
-- interval is safe.
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('cleanup-stale-source-runs');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Skipping unschedule of cleanup-stale-source-runs: %', SQLERRM;
  END;

  PERFORM cron.schedule(
    'cleanup-stale-source-runs',
    '*/30 * * * *',
    $sql$SELECT private.cleanup_stale_source_runs();$sql$
  );
END
$$;

COMMIT;
