-- Rollback for 20260601016000_anon_access_for_public_browsing.sql
-- Reverts the anon SELECT grants and the two deny-all anon policies the migration
-- added, returning anon to its pre-migration state (no access to these events_enriched
-- JOIN targets). Only the grant the migration added to public.ratings is revoked — the
-- pre-existing "Anon can read ratings for published events" policy predates this
-- migration and is left untouched.
BEGIN;

DROP POLICY IF EXISTS "Anon sees no favorites" ON public.favorites;
DROP POLICY IF EXISTS "Anon sees no calendar events" ON public.user_calendar_events;

REVOKE SELECT ON public.favorites FROM anon;
REVOKE SELECT ON public.user_calendar_events FROM anon;
REVOKE SELECT ON public.ratings FROM anon;

COMMIT;
