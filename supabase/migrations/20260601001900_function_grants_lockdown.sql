-- Lock down EXECUTE grants on SECURITY DEFINER functions in public.
-- ----------------------------------------------------------------
-- Supabase's default privileges grant EXECUTE on every new public function to
-- anon + authenticated. Prior migrations did `REVOKE ALL ... FROM PUBLIC` but
-- that does not remove those explicit role grants — so the advisor was right:
-- anon could call admin_*, cron-internal, and trigger functions via
-- /rest/v1/rpc/*. The functions self-gate where it matters (admin_* check
-- `private.is_admin()`), but we want defense in depth and a clean advisor run.
--
-- This migration:
--   * Revokes EXECUTE from anon + authenticated on cron/worker/trigger
--     functions that have zero legitimate caller from those roles.
--   * Revokes EXECUTE from anon on admin_* and authenticated-only flows.
--     Authenticated EXECUTE is kept because PostgREST routes those calls.
--
-- Functions intentionally left open to anon (sign-up + invite flow):
--   request_invite, redeem_invite, redeem_invite_for_email, invites_required.
-- The advisor will continue to flag those four; that is the correct posture.

BEGIN;

-- =============================================
-- 1. Internal / trigger / cron functions: revoke from anon + authenticated
-- =============================================

-- Trigger functions (fire on table writes; do not need RPC exposure)
REVOKE EXECUTE ON FUNCTION public.handle_new_user()                          FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.prevent_role_change()                      FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reset_comment_approval_for_non_admin()     FROM anon, authenticated;

-- Cron / worker functions (called by pg_cron under postgres or by edge
-- functions under service_role)
REVOKE EXECUTE ON FUNCTION public.invoke_scrape_source(uuid)                 FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.invoke_process_tag_queue()                 FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.run_due_source_scrapes()                   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.claim_tag_queue_batch(integer)             FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reap_stuck_tag_queue_rows()                FROM anon, authenticated;

-- =============================================
-- 2. Admin functions: revoke from anon (authenticated path stays)
-- =============================================
REVOKE EXECUTE ON FUNCTION public.admin_approve_invite_request(uuid)         FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_bulk_set_auto_approve(boolean)       FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_create_invite_code(integer, timestamptz, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_cron_run_history(text, integer)      FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_list_cron_jobs()                     FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_reject_invite_request(uuid, text)    FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_retry_tag_queue(uuid)                FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_run_due_scrapes()                    FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_cron_schedule(text, text)        FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_toggle_cron_job(text, boolean)       FROM anon;

-- =============================================
-- 3. Authenticated-only user-flow functions: revoke from anon
-- =============================================
REVOKE EXECUTE ON FUNCTION public.claim_pending_invite_access()              FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_enabled_user()                          FROM anon;
REVOKE EXECUTE ON FUNCTION public.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
) FROM anon;

-- =============================================
-- 4. Intentionally NOT revoked (anon sign-up / invite flow):
--    request_invite(text, text), redeem_invite(text),
--    redeem_invite_for_email(text, text), invites_required()
-- =============================================

COMMIT;
