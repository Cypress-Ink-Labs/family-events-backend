-- Rollback for 20260601033000_community_event_submission.sql
-- Reverts:
--   - DROP public.submit_community_event (public wrapper function)
--   - DROP private.submit_community_event_impl (private implementation)
--   - DROP COLUMN public.events.submitted_by
-- DATA LOSS CAVEAT: Dropping submitted_by destroys which user submitted each
-- community event. This cannot be recovered unless you have a backup.

BEGIN;

-- 1. Drop public wrapper and private implementation (reverse dependency order).
DROP FUNCTION IF EXISTS public.submit_community_event(
  text, text, timestamptz, timestamptz, text, text, uuid, integer, integer, boolean, numeric
);
DROP FUNCTION IF EXISTS private.submit_community_event_impl(
  text, text, timestamptz, timestamptz, text, text, uuid, integer, integer, boolean, numeric
);

-- 2. Drop the submitted_by column added by this migration.
--    DATA LOSS: existing submitted_by values are permanently lost.
ALTER TABLE public.events DROP COLUMN IF EXISTS submitted_by;

COMMIT;
