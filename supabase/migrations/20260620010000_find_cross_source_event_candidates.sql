-- CIL-16: Cross-source fuzzy deduplication at ingest time.
--
-- Provides an RPC that the scrape-source edge function calls BEFORE
-- bulk_import_scrape_events to fetch existing events in a time window so the
-- TS pre-pass can compare titles via Jaccard similarity and skip near-duplicates
-- from different sources.
--
-- The query intentionally does NOT filter on status so drafts already queued from
-- another source are also considered candidates. Rejected events are excluded to
-- avoid blocking a re-scraped event that was mistakenly rejected earlier.
--
-- Paired rollback:
--   supabase/rollbacks/20260620010000_find_cross_source_event_candidates_down.sql

CREATE OR REPLACE FUNCTION public.find_cross_source_event_candidates(
  p_city_id   uuid,
  p_start_from timestamptz,
  p_start_to   timestamptz,
  p_limit      integer DEFAULT 500
)
RETURNS TABLE (
  id             uuid,
  title          text,
  source_id      uuid,
  start_datetime timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT
    e.id,
    e.title,
    e.source_id,
    e.start_datetime
  FROM public.events e
  WHERE e.city_id = p_city_id
    AND e.start_datetime BETWEEN p_start_from AND p_start_to
    AND e.status <> 'rejected'::public.event_status
  ORDER BY e.start_datetime
  LIMIT LEAST(GREATEST(p_limit, 1), 1000);
$$;

REVOKE ALL ON FUNCTION public.find_cross_source_event_candidates(uuid, timestamptz, timestamptz, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_cross_source_event_candidates(uuid, timestamptz, timestamptz, integer)
  TO service_role;
