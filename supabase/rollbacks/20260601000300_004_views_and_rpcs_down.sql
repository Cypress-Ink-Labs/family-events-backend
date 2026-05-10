-- Rollback: drop views and RPCs
DROP FUNCTION IF EXISTS public.plan_events_for_user(uuid, date, uuid, double precision, double precision, integer, text, integer);
DROP FUNCTION IF EXISTS public.events_enriched(uuid, text, int, int, uuid, uuid[], timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.search_events(uuid, timestamptz, timestamptz, int, int, boolean, boolean, text[], text, text, int, int);
DROP VIEW IF EXISTS public.public_events;
DROP VIEW IF EXISTS public.event_rating_stats;
