-- Production readiness program U2: redrive the dead-letter backlog created by
-- the stale-status constraint bug (fixed in 20260816000000).
--
-- private.redrive_constraint_bug_dead_letters(p_dry_run):
--   * targets only dead queue rows whose last_error carries the
--     event_sources_last_status_check signature (SQLSTATE 23514) — dead rows
--     with unrelated causes need triage, not blind redrive;
--   * skips any source that already has an active (pending/processing/retrying)
--     queue row — the scheduler may have re-enqueued it since, and the queue
--     has no per-source uniqueness;
--   * redrives at most one row per source (the most recently enqueued match);
--   * p_dry_run => true returns the would-be-redriven rows without writing,
--     so the operator reviews the set before applying.
--
-- Operator usage:
--   SELECT * FROM private.redrive_constraint_bug_dead_letters(true);   -- review
--   SELECT * FROM private.redrive_constraint_bug_dead_letters(false);  -- apply
--
-- Paired rollback:
--   supabase/rollbacks/20260816001000_redrive_constraint_bug_dead_letters_down.sql

CREATE OR REPLACE FUNCTION private.redrive_constraint_bug_dead_letters(
  p_dry_run boolean DEFAULT true
) RETURNS TABLE (
  queue_id bigint,
  source_id uuid,
  last_error text,
  redriven boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT DISTINCT ON (q.source_id)
      q.id,
      q.source_id AS src_id,
      q.last_error AS err
    FROM public.source_scrape_queue q
    WHERE q.status = 'dead'
      AND q.last_error ILIKE '%event_sources_last_status_check%'
      AND q.source_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.source_scrape_queue active
        WHERE active.source_id = q.source_id
          AND active.status IN ('pending', 'processing', 'retrying')
      )
    ORDER BY q.source_id, q.enqueued_at DESC
  ),
  applied AS (
    UPDATE public.source_scrape_queue q
    SET status = 'pending',
        attempt_count = 0,
        started_at = NULL,
        finished_at = NULL,
        next_attempt_at = now(),
        skip_reason = NULL
    FROM candidates c
    WHERE q.id = c.id
      AND NOT p_dry_run
    RETURNING q.id
  )
  SELECT
    c.id,
    c.src_id,
    c.err,
    (NOT p_dry_run) AS redriven
  FROM candidates c;
END;
$$;

REVOKE ALL ON FUNCTION private.redrive_constraint_bug_dead_letters(boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION private.redrive_constraint_bug_dead_letters(boolean) TO service_role;
