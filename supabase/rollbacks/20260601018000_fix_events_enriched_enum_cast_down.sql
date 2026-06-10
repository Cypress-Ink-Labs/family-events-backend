-- Rollback for 20260601018000_fix_events_enriched_enum_cast.sql
-- Reverts:
--   - DROP of old offset-based public.events_enriched overload (re-creates it below)
--   - CREATE OR REPLACE of the enum-cast offset-based events_enriched body
-- Strategy: 018000 created an offset-based overload and dropped it first as a
--   safety step. Its down simply drops that overload. The cursor-based canonical
--   signature is managed by 019000; run 019000_down BEFORE this one.
-- Data-loss caveat: none — function-only change.

BEGIN;

-- Drop the offset-based overload introduced by 018000.
DROP FUNCTION IF EXISTS public.events_enriched(uuid, text, integer, integer, uuid, uuid[], timestamptz, timestamptz);

COMMIT;
