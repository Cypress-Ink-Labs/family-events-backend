-- Rollback for 20260601034000_activate_baton_rouge_sources.sql
-- Pure DATA revert: sets is_active = false for the same four sources that
-- the UP migration activated.
-- CAVEAT: If any of these sources were already active before the UP migration
-- ran, this rollback will incorrectly deactivate them. Check is_active state
-- in a backup before running if that matters.

BEGIN;

UPDATE public.event_sources
SET is_active = false
WHERE name IN (
  'BREC Parks',
  'BREC Kids Calendar',
  'City-Parish Main Calendar',
  'LocalHop Baton Rouge'
);

COMMIT;
