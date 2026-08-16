-- Rollback for 20260816000000_event_sources_allow_stale_status.sql
--
-- Restores the original baseline constraint (no 'stale'). Any rows that hold
-- last_status = 'stale' must be normalized first or the ADD CONSTRAINT fails —
-- that is intentional: rolling back with stale rows present would silently
-- reintroduce the 23514 dead-letter bug on live data.

UPDATE public.event_sources
SET last_status = 'error'
WHERE last_status = 'stale';

ALTER TABLE public.event_sources
  DROP CONSTRAINT event_sources_last_status_check;

ALTER TABLE public.event_sources
  ADD CONSTRAINT event_sources_last_status_check
  CHECK (last_status = ANY (ARRAY[
    'pending'::text,
    'success'::text,
    'error'::text,
    'partial'::text
  ]));
