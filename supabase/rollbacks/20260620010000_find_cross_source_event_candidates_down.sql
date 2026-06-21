-- Rollback for 20260620010000_find_cross_source_event_candidates.sql
--
-- Drops the RPC added for CIL-16 cross-source fuzzy dedup.
-- After applying this rollback the scrape-source edge function will detect the
-- missing RPC (error code 42883) and skip dedup, falling back to importing all events.

DROP FUNCTION IF EXISTS public.find_cross_source_event_candidates(uuid, timestamptz, timestamptz, integer);
