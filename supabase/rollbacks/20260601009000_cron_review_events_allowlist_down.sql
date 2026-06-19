-- Rollback for 20260601009000_cron_review_events_allowlist.sql
-- Reverses the two UP effects:
--   1. Seed INSERT of the 'cron-review-events' label into private.cron_enabled.
--      Inverse: DELETE that label. (009000 is the ONLY migration that inserts it.)
--   2. CREATE OR REPLACE of private.list_railway_cron_jobs() that ADDED
--      'cron-review-events' to the hardcoded `known` labels array.
--      Restored body = the most-recent prior definition with timestamp < 009000:
--      20260601002000_event_ingestion_admin_foundation.sql:851 (5 labels, no
--      cron-review-events). Verified: the 009000 body differs from the 002000:851
--      body ONLY by the added 'cron-review-events' entry. Earlier still is the
--      fresh CREATE FUNCTION at 20260601001000_reference_security_and_cron.sql:644
--      (4 labels); not used, per "most recent def < target".
--
-- NOTE (grants): 002000:851 and 009000 both use bare CREATE OR REPLACE with no
-- GRANT/REVOKE. The grants were set once at the fresh CREATE FUNCTION
-- (001000:690-691: REVOKE FROM PUBLIC,anon,authenticated; GRANT EXECUTE TO
-- authenticated,service_role) and CREATE OR REPLACE preserves them. So this
-- rollback intentionally emits NO grant statements — restoring grants here would
-- be asymmetric. SECURITY DEFINER + SET search_path = '' + is_admin() guard are
-- all preserved in the restored body below.
--
-- NOTE (cron_enabled DELETE): pre-009000 there was no 'cron-review-events' row,
-- so list_railway_cron_jobs() reported enabled=true for it via the COALESCE
-- default. Deleting the row restores that exact prior behavior. If an admin has
-- since toggled the row to enabled=false, that state is discarded on rollback —
-- correct, since the row did not exist before 009000.

BEGIN;

-- 1. Restore private.list_railway_cron_jobs() to its pre-009000 body.
--    Body copied verbatim from 20260601002000_event_ingestion_admin_foundation.sql:851,
--    the only difference vs 009000 being the removed 'cron-review-events' label.
CREATE OR REPLACE FUNCTION private.list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  enabled             boolean,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH known AS (
    SELECT unnest(ARRAY[
      'cron-db-maintenance',
      'cron-tag-queue',
      'cron-scrape-sources',
      'cron-cleanup-stale',
      'cron-enrich-events'
    ]::text[]) AS label
  ),
  last_runs AS (
    SELECT DISTINCT ON (r.label)
      r.label, r.status, r.ran_at, r.duration_s, r.http_status
    FROM private.railway_cron_runs r
    ORDER BY r.label, r.ran_at DESC
  )
  SELECT
    k.label,
    COALESCE((SELECT ce.enabled FROM private.cron_enabled ce WHERE ce.label = k.label), true) AS enabled,
    lr.status,
    lr.ran_at,
    lr.duration_s,
    lr.http_status
  FROM known k
  LEFT JOIN last_runs lr ON lr.label = k.label
  ORDER BY k.label;
END;
$$;

-- 2. Remove the seeded cron label (inverse of the UP INSERT ... ON CONFLICT DO NOTHING).
DELETE FROM private.cron_enabled WHERE label = 'cron-review-events';

COMMIT;
