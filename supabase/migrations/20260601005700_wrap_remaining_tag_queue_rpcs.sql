-- Wrap the two remaining SECURITY DEFINER tag-queue RPCs behind public
-- SECURITY INVOKER wrappers, matching the pattern established in
-- 20260601002100 and 20260601005100. Closes advisor lints 0028/0029 for
-- these functions and removes the last definers in the queue surface.
--
-- 2 functions covered:
--   claim_tag_queue_batch, reap_stuck_tag_queue_rows.
--
-- Callers today are service_role (process-tag-queue edge function). Pattern:
-- the private body keeps SECURITY DEFINER for the row-locking UPDATE; the
-- public wrapper is SECURITY INVOKER and the caller still needs EXECUTE on
-- the private function + USAGE on schema `private`. USAGE was granted to
-- service_role in 20260601005600.

BEGIN;

-- =============================================
-- 1. Move bodies to private schema.
-- =============================================
ALTER FUNCTION public.claim_tag_queue_batch(integer)          SET SCHEMA private;
ALTER FUNCTION public.reap_stuck_tag_queue_rows()             SET SCHEMA private;

-- =============================================
-- 2. Tighten grants on the private functions. Service-role only.
-- =============================================
REVOKE EXECUTE ON FUNCTION private.claim_tag_queue_batch(integer)   FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.claim_tag_queue_batch(integer)   TO service_role;

REVOKE EXECUTE ON FUNCTION private.reap_stuck_tag_queue_rows()      FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reap_stuck_tag_queue_rows()      TO service_role;

-- =============================================
-- 3. Public SECURITY INVOKER wrappers. Defaults preserved.
-- =============================================

-- claim_tag_queue_batch: RETURNS SETOF event_tag_queue, p_limit default 5
CREATE OR REPLACE FUNCTION public.claim_tag_queue_batch(p_limit integer DEFAULT 5)
RETURNS SETOF public.event_tag_queue
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.claim_tag_queue_batch(p_limit); $$;

-- reap_stuck_tag_queue_rows: RETURNS int
CREATE OR REPLACE FUNCTION public.reap_stuck_tag_queue_rows()
RETURNS integer
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.reap_stuck_tag_queue_rows(); $$;

-- =============================================
-- 4. Grants on the new public wrappers. Service-role only.
-- =============================================
REVOKE EXECUTE ON FUNCTION public.claim_tag_queue_batch(integer)    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reap_stuck_tag_queue_rows()       FROM PUBLIC, anon, authenticated;

COMMIT;
