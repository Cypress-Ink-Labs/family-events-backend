-- P0-003: RLS/RPC query-plan indexes.
--
-- Benchmarked with supabase/benchmarks/p0_003_rls_rpc_benchmarks.sql.
-- Targets:
-- - city/date scans of published events through events_enriched, search_events,
--   and public_events.
-- - city-scoped candidate selection inside plan_events_for_user.
-- - approved comment reads under the anon/authenticated RLS policies.

BEGIN;

CREATE INDEX IF NOT EXISTS events_published_city_start_datetime_idx
  ON public.events (city_id, start_datetime)
  WHERE status = 'published';

CREATE INDEX IF NOT EXISTS comments_approved_event_created_at_idx
  ON public.comments (event_id, created_at DESC)
  WHERE is_approved = true;

COMMIT;
