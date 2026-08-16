-- Production readiness program U1: allow 'stale' in event_sources.last_status.
--
-- The stale-escalation path (scrape-source/lib/process-source.ts) writes
-- last_status = 'stale' when a source exceeds the zero-result threshold, and
-- scrape-source/lib/types.ts already types 'stale' as valid — but the check
-- constraint from the schema baseline only allows pending|success|error|partial.
-- Every stale escalation therefore fails with SQLSTATE 23514 and dead-letters
-- the source (54 sources accumulated over two months). Constraint-only fix;
-- no code change.
--
-- Paired rollback:
--   supabase/rollbacks/20260816000000_event_sources_allow_stale_status_down.sql

ALTER TABLE public.event_sources
  DROP CONSTRAINT event_sources_last_status_check;

ALTER TABLE public.event_sources
  ADD CONSTRAINT event_sources_last_status_check
  CHECK (last_status = ANY (ARRAY[
    'pending'::text,
    'success'::text,
    'error'::text,
    'partial'::text,
    'stale'::text
  ]));
