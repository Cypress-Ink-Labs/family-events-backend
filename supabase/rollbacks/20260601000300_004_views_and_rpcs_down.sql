-- Rollback: drop views and RPCs owned by 004.
-- NOTE: public.public_events lives in 001_schema.sql (because anon policies in
-- 003_rls.sql reference it inside USING clauses). Its DROP belongs in
-- 001_schema_down.sql, not here.
DROP FUNCTION IF EXISTS public.plan_events_for_user(uuid, date, uuid, double precision, double precision, integer, text, integer);
DROP FUNCTION IF EXISTS public.events_enriched(uuid, text, int, int, uuid, uuid[], timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.search_events(uuid, timestamptz, timestamptz, int, int, boolean, boolean, text[], text, text, int, int);
DROP VIEW IF EXISTS public.event_rating_stats;
