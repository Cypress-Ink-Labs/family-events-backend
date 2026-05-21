-- Wrap the queue/maintenance SECURITY DEFINER RPCs introduced after
-- 20260601002100_wrap_security_definer_rpcs.sql behind SECURITY INVOKER
-- public wrappers, silencing advisor lints 0028/0029.
--
-- Pattern (per CLAUDE.md): private body owns DEFINER privileges, the public
-- wrapper is a thin SECURITY INVOKER passthrough so PostgREST clients keep
-- the same signature. Default values on the public wrapper are preserved.
--
-- 11 functions covered:
--   admin_retry_source_scrape_queue, admin_run_due_scrapes,
--   claim_source_scrape_queue_batch, mark_source_scrape_queue_skipped,
--   mark_source_scrape_queue_started, mark_tag_queue_row_started,
--   reap_stuck_source_scrape_queue_rows,
--   release_unstarted_source_scrape_queue_rows,
--   release_unstarted_tag_queue_rows, run_daily_maintenance,
--   source_scrape_queue_schedule_retry.

BEGIN;

-- =============================================
-- 0. admin_run_due_scrapes was wrapped in 2100, then redefined as a public
--    SECURITY DEFINER by 4300, which silently recreated the public copy and
--    left the private copy stale. Drop the stale private body so the upcoming
--    ALTER ... SET SCHEMA private succeeds.
-- =============================================
DROP FUNCTION IF EXISTS private.admin_run_due_scrapes();

-- =============================================
-- 1. Move bodies to private schema.
-- =============================================
ALTER FUNCTION public.admin_retry_source_scrape_queue(bigint)                       SET SCHEMA private;
ALTER FUNCTION public.admin_run_due_scrapes()                                       SET SCHEMA private;
ALTER FUNCTION public.claim_source_scrape_queue_batch(integer)                      SET SCHEMA private;
ALTER FUNCTION public.mark_source_scrape_queue_skipped(bigint, text)                SET SCHEMA private;
ALTER FUNCTION public.mark_source_scrape_queue_started(bigint)                      SET SCHEMA private;
ALTER FUNCTION public.mark_tag_queue_row_started(bigint)                            SET SCHEMA private;
ALTER FUNCTION public.reap_stuck_source_scrape_queue_rows()                         SET SCHEMA private;
ALTER FUNCTION public.release_unstarted_source_scrape_queue_rows(bigint[])          SET SCHEMA private;
ALTER FUNCTION public.release_unstarted_tag_queue_rows(bigint[])                    SET SCHEMA private;
ALTER FUNCTION public.run_daily_maintenance()                                       SET SCHEMA private;
ALTER FUNCTION public.source_scrape_queue_schedule_retry(bigint, integer, text)     SET SCHEMA private;

-- =============================================
-- 2. Tighten grants on the private functions. Each role gets EXECUTE only if
--    it can legitimately reach the public wrapper.
-- =============================================

-- Admin RPCs: authenticated reaches them (admin self-check inside private body).
REVOKE EXECUTE ON FUNCTION private.admin_retry_source_scrape_queue(bigint)          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_retry_source_scrape_queue(bigint)          TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_run_due_scrapes()                          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_run_due_scrapes()                          TO authenticated, service_role;

-- Service-role-only RPCs (queue workers invoked by edge functions).
REVOKE EXECUTE ON FUNCTION private.claim_source_scrape_queue_batch(integer)         FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.claim_source_scrape_queue_batch(integer)         TO service_role;
REVOKE EXECUTE ON FUNCTION private.mark_source_scrape_queue_skipped(bigint, text)   FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.mark_source_scrape_queue_skipped(bigint, text)   TO service_role;
REVOKE EXECUTE ON FUNCTION private.mark_source_scrape_queue_started(bigint)         FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.mark_source_scrape_queue_started(bigint)         TO service_role;
REVOKE EXECUTE ON FUNCTION private.mark_tag_queue_row_started(bigint)               FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.mark_tag_queue_row_started(bigint)               TO service_role;
REVOKE EXECUTE ON FUNCTION private.reap_stuck_source_scrape_queue_rows()            FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reap_stuck_source_scrape_queue_rows()            TO service_role;
REVOKE EXECUTE ON FUNCTION private.release_unstarted_source_scrape_queue_rows(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.release_unstarted_source_scrape_queue_rows(bigint[]) TO service_role;
REVOKE EXECUTE ON FUNCTION private.release_unstarted_tag_queue_rows(bigint[])       FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.release_unstarted_tag_queue_rows(bigint[])       TO service_role;
REVOKE EXECUTE ON FUNCTION private.run_daily_maintenance()                          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.run_daily_maintenance()                          TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION private.source_scrape_queue_schedule_retry(bigint, integer, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.source_scrape_queue_schedule_retry(bigint, integer, text) TO service_role;

-- =============================================
-- 3. Public SECURITY INVOKER wrappers. SQL bodies — minimal surface.
--    Defaults preserved on the wrapper.
-- =============================================

-- admin_retry_source_scrape_queue: RETURNS boolean
CREATE OR REPLACE FUNCTION public.admin_retry_source_scrape_queue(p_queue_id bigint)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_retry_source_scrape_queue(p_queue_id); $$;

-- admin_run_due_scrapes: RETURNS void
CREATE OR REPLACE FUNCTION public.admin_run_due_scrapes()
RETURNS void
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_run_due_scrapes(); $$;

-- claim_source_scrape_queue_batch: RETURNS SETOF source_scrape_queue, p_limit default 5
CREATE OR REPLACE FUNCTION public.claim_source_scrape_queue_batch(p_limit integer DEFAULT 5)
RETURNS SETOF public.source_scrape_queue
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.claim_source_scrape_queue_batch(p_limit); $$;

-- mark_source_scrape_queue_skipped: RETURNS void
CREATE OR REPLACE FUNCTION public.mark_source_scrape_queue_skipped(
  p_queue_id bigint,
  p_skip_reason text
)
RETURNS void
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.mark_source_scrape_queue_skipped(p_queue_id, p_skip_reason); $$;

-- mark_source_scrape_queue_started: RETURNS source_scrape_queue (composite)
CREATE OR REPLACE FUNCTION public.mark_source_scrape_queue_started(p_queue_id bigint)
RETURNS public.source_scrape_queue
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.mark_source_scrape_queue_started(p_queue_id); $$;

-- mark_tag_queue_row_started: RETURNS event_tag_queue (composite)
CREATE OR REPLACE FUNCTION public.mark_tag_queue_row_started(p_queue_id bigint)
RETURNS public.event_tag_queue
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.mark_tag_queue_row_started(p_queue_id); $$;

-- reap_stuck_source_scrape_queue_rows: RETURNS int
CREATE OR REPLACE FUNCTION public.reap_stuck_source_scrape_queue_rows()
RETURNS integer
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.reap_stuck_source_scrape_queue_rows(); $$;

-- release_unstarted_source_scrape_queue_rows: RETURNS int
CREATE OR REPLACE FUNCTION public.release_unstarted_source_scrape_queue_rows(p_claimed_ids bigint[])
RETURNS integer
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.release_unstarted_source_scrape_queue_rows(p_claimed_ids); $$;

-- release_unstarted_tag_queue_rows: RETURNS int
CREATE OR REPLACE FUNCTION public.release_unstarted_tag_queue_rows(p_claimed_ids bigint[])
RETURNS integer
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.release_unstarted_tag_queue_rows(p_claimed_ids); $$;

-- run_daily_maintenance: RETURNS jsonb
CREATE OR REPLACE FUNCTION public.run_daily_maintenance()
RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.run_daily_maintenance(); $$;

-- source_scrape_queue_schedule_retry: RETURNS void
CREATE OR REPLACE FUNCTION public.source_scrape_queue_schedule_retry(
  p_queue_id bigint,
  p_attempt_count integer,
  p_error text
)
RETURNS void
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.source_scrape_queue_schedule_retry(p_queue_id, p_attempt_count, p_error); $$;

-- =============================================
-- 4. Grants on the new public wrappers.
--    Supabase default privileges hand EXECUTE to anon+authenticated+service_role
--    on every new public function. REVOKE everywhere they should not reach.
-- =============================================

-- Admin RPCs: authenticated only.
REVOKE EXECUTE ON FUNCTION public.admin_retry_source_scrape_queue(bigint)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_run_due_scrapes()                           FROM PUBLIC, anon;

-- Service-role-only RPCs.
REVOKE EXECUTE ON FUNCTION public.claim_source_scrape_queue_batch(integer)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mark_source_scrape_queue_skipped(bigint, text)    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mark_source_scrape_queue_started(bigint)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mark_tag_queue_row_started(bigint)                FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reap_stuck_source_scrape_queue_rows()             FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_unstarted_source_scrape_queue_rows(bigint[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_unstarted_tag_queue_rows(bigint[])        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.run_daily_maintenance()                           FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.source_scrape_queue_schedule_retry(bigint, integer, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.run_daily_maintenance()                            TO postgres;

COMMIT;
