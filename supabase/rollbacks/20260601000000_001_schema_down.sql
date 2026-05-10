-- Rollback: drop all tables in reverse dependency order.
-- Drop dependent view first so the CASCADE on events doesn't trip view drops.
DROP VIEW IF EXISTS public.public_events;

DROP TABLE IF EXISTS public.event_ai_traces CASCADE;
DROP TABLE IF EXISTS public.pending_invite_claims CASCADE;
DROP TABLE IF EXISTS public.user_access CASCADE;
DROP TABLE IF EXISTS public.invite_codes CASCADE;
DROP TABLE IF EXISTS public.admin_audit_log CASCADE;
DROP TABLE IF EXISTS public.recommendation_signals CASCADE;
DROP TABLE IF EXISTS public.comments CASCADE;
DROP TABLE IF EXISTS public.ratings CASCADE;
DROP TABLE IF EXISTS public.user_calendar_events CASCADE;
DROP TABLE IF EXISTS public.favorites CASCADE;
DROP TABLE IF EXISTS public.event_tags CASCADE;
DROP TABLE IF EXISTS public.events CASCADE;
DROP TABLE IF EXISTS public.source_runs CASCADE;
DROP TABLE IF EXISTS public.event_sources CASCADE;
DROP TABLE IF EXISTS public.user_profiles CASCADE;
DROP TABLE IF EXISTS public.tags CASCADE;
DROP TABLE IF EXISTS public.cities CASCADE;

DROP SCHEMA IF EXISTS private CASCADE;
