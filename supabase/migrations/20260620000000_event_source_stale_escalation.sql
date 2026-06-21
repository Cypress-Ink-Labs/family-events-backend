-- Plan CIL-18: Stale source admin alerting.
--
-- A source that returns 0 events repeatedly looks healthy (last_status='success',
-- error_count=0). This migration adds tracking columns and tightens the scheduler
-- query so stale-escalated sources are skipped automatically.
--
-- Paired rollback:
--   supabase/rollbacks/20260620000000_event_source_stale_escalation_down.sql

-- ---------------------------------------------------------------------------
-- New columns on public.event_sources
-- ---------------------------------------------------------------------------

ALTER TABLE public.event_sources
  ADD COLUMN consecutive_zero_result_scrapes integer NOT NULL DEFAULT 0;

ALTER TABLE public.event_sources
  ADD COLUMN stale_escalated_at timestamptz;

-- ---------------------------------------------------------------------------
-- Due-source selection: exclude stale-escalated sources from scheduling.
--
-- Replaces the body from 20260601001000_reference_security_and_cron.sql.
-- The only change is the extra AND clause: AND s.stale_escalated_at IS NULL
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.due_event_sources(p_limit integer DEFAULT 200)
RETURNS SETOF public.event_sources
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT s.*
  FROM public.event_sources s
  WHERE s.is_active = true
    AND s.stale_escalated_at IS NULL
    AND (
      s.last_scraped_at IS NULL
      OR s.last_scraped_at + make_interval(hours => s.scrape_interval_hours) <= now()
    )
  ORDER BY s.last_scraped_at ASC NULLS FIRST, s.id ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 500);
$$;

REVOKE ALL ON FUNCTION public.due_event_sources(integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.due_event_sources(integer) TO service_role;
