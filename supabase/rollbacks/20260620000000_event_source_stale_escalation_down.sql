-- Rollback for 20260620000000_event_source_stale_escalation.sql
--
-- Drops the two new columns and restores due_event_sources() to its prior body
-- from 20260601001000_reference_security_and_cron.sql (without the
-- stale_escalated_at IS NULL guard).

-- ---------------------------------------------------------------------------
-- Restore due_event_sources() to the pre-CIL-18 body (no stale filter).
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
    AND (
      s.last_scraped_at IS NULL
      OR s.last_scraped_at + make_interval(hours => s.scrape_interval_hours) <= now()
    )
  ORDER BY s.last_scraped_at ASC NULLS FIRST, s.id ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 500);
$$;

REVOKE ALL ON FUNCTION public.due_event_sources(integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.due_event_sources(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Drop the new columns added by the forward migration.
-- ---------------------------------------------------------------------------

ALTER TABLE public.event_sources
  DROP COLUMN IF EXISTS stale_escalated_at;

ALTER TABLE public.event_sources
  DROP COLUMN IF EXISTS consecutive_zero_result_scrapes;
