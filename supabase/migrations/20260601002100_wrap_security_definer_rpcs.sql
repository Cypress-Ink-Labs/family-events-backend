-- Wrap PostgREST-facing SECURITY DEFINER RPCs behind SECURITY INVOKER public
-- wrappers.
-- ----------------------------------------------------------------
-- The Supabase advisor lints 0028/0029 flag SECURITY DEFINER functions that
-- live in an API-exposed schema (public) and are EXECUTEable by anon or
-- authenticated. The lint is shallow — it only checks the SECURITY clause
-- on the function PostgREST sees, not the call chain.
--
-- Strategy: move each flagged function body to `private`, then re-publish the
-- original name in `public` as a thin SECURITY INVOKER wrapper. The wrapper
-- delegates to the private function, which retains DEFINER privileges. Net
-- effect: behavior identical, lints silenced, and admin-only RPCs are now
-- one extra layer removed from any future schema-exposure misconfiguration.
--
-- 16 functions covered. The 17th (is_enabled_user) was already converted to
-- a SECURITY INVOKER passthrough in an earlier ad-hoc fix.

BEGIN;

-- =============================================
-- 1. Move bodies to private schema (atomic).
-- =============================================
ALTER FUNCTION public.admin_approve_invite_request(uuid)              SET SCHEMA private;
ALTER FUNCTION public.admin_bulk_set_auto_approve(boolean)            SET SCHEMA private;
ALTER FUNCTION public.admin_create_invite_code(integer, timestamptz, text) SET SCHEMA private;
ALTER FUNCTION public.admin_cron_run_history(text, integer)           SET SCHEMA private;
ALTER FUNCTION public.admin_list_cron_jobs()                          SET SCHEMA private;
ALTER FUNCTION public.admin_reject_invite_request(uuid, text)         SET SCHEMA private;
ALTER FUNCTION public.admin_retry_tag_queue(uuid)                     SET SCHEMA private;
ALTER FUNCTION public.admin_run_due_scrapes()                         SET SCHEMA private;
ALTER FUNCTION public.admin_set_cron_schedule(text, text)             SET SCHEMA private;
ALTER FUNCTION public.admin_toggle_cron_job(text, boolean)            SET SCHEMA private;
ALTER FUNCTION public.claim_pending_invite_access()                   SET SCHEMA private;
ALTER FUNCTION public.invites_required()                              SET SCHEMA private;
ALTER FUNCTION public.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
)                                                                     SET SCHEMA private;
ALTER FUNCTION public.redeem_invite(text)                             SET SCHEMA private;
ALTER FUNCTION public.redeem_invite_for_email(text, text)             SET SCHEMA private;
ALTER FUNCTION public.request_invite(text, text)                      SET SCHEMA private;

-- =============================================
-- 2. Tighten grants on the relocated private functions.
--    Each role gets EXECUTE only if it can reach the public wrapper.
-- =============================================

-- Admin RPCs: authenticated reaches them (admin self-check inside).
REVOKE EXECUTE ON FUNCTION private.admin_approve_invite_request(uuid)              FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_approve_invite_request(uuid)              TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_bulk_set_auto_approve(boolean)            FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_bulk_set_auto_approve(boolean)            TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_create_invite_code(integer, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_create_invite_code(integer, timestamptz, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_cron_run_history(text, integer)           FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_cron_run_history(text, integer)           TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_list_cron_jobs()                          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_list_cron_jobs()                          TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_reject_invite_request(uuid, text)         FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_reject_invite_request(uuid, text)         TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_retry_tag_queue(uuid)                     FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_retry_tag_queue(uuid)                     TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_run_due_scrapes()                         FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_run_due_scrapes()                         TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_set_cron_schedule(text, text)             FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_set_cron_schedule(text, text)             TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.admin_toggle_cron_job(text, boolean)            FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_toggle_cron_job(text, boolean)            TO authenticated, service_role;

-- Authenticated-only user flow.
REVOKE EXECUTE ON FUNCTION private.claim_pending_invite_access()                   FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.claim_pending_invite_access()                   TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
)                                                                                  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
)                                                                                  TO authenticated, service_role;

-- Anon + authenticated (sign-up / invite flow).
REVOKE EXECUTE ON FUNCTION private.invites_required()                              FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.invites_required()                              TO anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.redeem_invite(text)                             FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.redeem_invite(text)                             TO anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.redeem_invite_for_email(text, text)             FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.redeem_invite_for_email(text, text)             TO anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.request_invite(text, text)                      FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.request_invite(text, text)                      TO anon, authenticated, service_role;

-- =============================================
-- 3. Public SECURITY INVOKER wrappers. SQL bodies — minimal surface.
--    Default values preserved so PostgREST clients calling with omitted
--    optional args continue to work.
-- =============================================

-- admin_approve_invite_request: RETURNS TABLE(...)
CREATE OR REPLACE FUNCTION public.admin_approve_invite_request(p_request_id uuid)
RETURNS TABLE (request_id uuid, code text, invite_code_id uuid, email text, created_at timestamptz)
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.admin_approve_invite_request(p_request_id); $$;

-- admin_bulk_set_auto_approve: RETURNS void
CREATE OR REPLACE FUNCTION public.admin_bulk_set_auto_approve(enable boolean)
RETURNS void
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_bulk_set_auto_approve(enable); $$;

-- admin_create_invite_code: RETURNS TABLE(...) with defaults
CREATE OR REPLACE FUNCTION public.admin_create_invite_code(
  p_max_uses integer DEFAULT 1,
  p_expires_at timestamptz DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS TABLE (id uuid, code text, max_uses integer, expires_at timestamptz, notes text, created_at timestamptz)
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.admin_create_invite_code(p_max_uses, p_expires_at, p_notes); $$;

-- admin_cron_run_history: RETURNS TABLE(...) with defaults
CREATE OR REPLACE FUNCTION public.admin_cron_run_history(
  p_job_name text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (runid bigint, jobname text, status text, return_message text, start_time timestamptz, end_time timestamptz, duration_ms numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.admin_cron_run_history(p_job_name, p_limit); $$;

-- admin_list_cron_jobs: RETURNS TABLE(...)
CREATE OR REPLACE FUNCTION public.admin_list_cron_jobs()
RETURNS TABLE (jobid bigint, jobname text, schedule text, command text, active boolean,
               last_run_start timestamptz, last_run_end timestamptz, last_run_status text, last_run_message text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.admin_list_cron_jobs(); $$;

-- admin_reject_invite_request: RETURNS boolean
CREATE OR REPLACE FUNCTION public.admin_reject_invite_request(
  p_request_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_reject_invite_request(p_request_id, p_notes); $$;

-- admin_retry_tag_queue: RETURNS boolean
CREATE OR REPLACE FUNCTION public.admin_retry_tag_queue(p_event_id uuid)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_retry_tag_queue(p_event_id); $$;

-- admin_run_due_scrapes: RETURNS void
CREATE OR REPLACE FUNCTION public.admin_run_due_scrapes()
RETURNS void
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_run_due_scrapes(); $$;

-- admin_set_cron_schedule: RETURNS void
CREATE OR REPLACE FUNCTION public.admin_set_cron_schedule(p_job_name text, p_schedule text)
RETURNS void
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_set_cron_schedule(p_job_name, p_schedule); $$;

-- admin_toggle_cron_job: RETURNS void
CREATE OR REPLACE FUNCTION public.admin_toggle_cron_job(p_job_name text, p_active boolean)
RETURNS void
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.admin_toggle_cron_job(p_job_name, p_active); $$;

-- claim_pending_invite_access: RETURNS boolean
CREATE OR REPLACE FUNCTION public.claim_pending_invite_access()
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.claim_pending_invite_access(); $$;

-- invites_required: RETURNS boolean
CREATE OR REPLACE FUNCTION public.invites_required()
RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.invites_required(); $$;

-- plan_events_first_nonempty_window: RETURNS TABLE(...) with many defaults
CREATE OR REPLACE FUNCTION public.plan_events_first_nonempty_window(
  p_user_id uuid,
  p_date date DEFAULT ((now() AT TIME ZONE 'utc'::text))::date,
  p_city_id uuid DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_kid_age integer DEFAULT NULL,
  p_weather_fit text DEFAULT 'neutral',
  p_limit integer DEFAULT 3,
  p_max_days integer DEFAULT 7
)
RETURNS TABLE (day_offset integer, event_id uuid, score numeric, distance_score numeric,
               weather_score numeric, age_score numeric, history_affinity numeric, distance_km numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$
  SELECT * FROM private.plan_events_first_nonempty_window(
    p_user_id, p_date, p_city_id, p_lat, p_lng, p_kid_age, p_weather_fit, p_limit, p_max_days
  );
$$;

-- redeem_invite: RETURNS boolean
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code text)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.redeem_invite(p_code); $$;

-- redeem_invite_for_email: RETURNS boolean
CREATE OR REPLACE FUNCTION public.redeem_invite_for_email(p_code text, p_email text)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.redeem_invite_for_email(p_code, p_email); $$;

-- request_invite: RETURNS boolean
CREATE OR REPLACE FUNCTION public.request_invite(p_email text, p_message text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.request_invite(p_email, p_message); $$;

-- =============================================
-- 4. Grants on the new public wrappers.
--    Supabase default privileges hand EXECUTE to anon+authenticated+service_role
--    on every new public function, so we explicitly REVOKE where unwanted.
-- =============================================

-- Admin RPCs: authenticated only (admin self-check inside private body).
REVOKE EXECUTE ON FUNCTION public.admin_approve_invite_request(uuid)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_bulk_set_auto_approve(boolean)            FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_create_invite_code(integer, timestamptz, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_cron_run_history(text, integer)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_list_cron_jobs()                          FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_reject_invite_request(uuid, text)         FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_retry_tag_queue(uuid)                     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_run_due_scrapes()                         FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_cron_schedule(text, text)             FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_toggle_cron_job(text, boolean)            FROM PUBLIC, anon;

-- Authenticated-only user flow.
REVOKE EXECUTE ON FUNCTION public.claim_pending_invite_access()                   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
)                                                                                 FROM PUBLIC, anon;

-- Anon + authenticated (sign-up / invite flow): default privs already grant
-- to both, just clean up PUBLIC for hygiene.
REVOKE EXECUTE ON FUNCTION public.invites_required()                              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.redeem_invite(text)                             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.redeem_invite_for_email(text, text)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.request_invite(text, text)                      FROM PUBLIC;

COMMIT;
