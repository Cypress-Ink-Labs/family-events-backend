/*
  # Toggleable Railway crons

  Railway cron services have no native pause API, so toggling them from the
  admin UI requires a DB-side kill switch the runner consults each tick.

  Adds:
    - private.cron_enabled (label PK, enabled BOOLEAN, updated_at)
    - public.is_cron_enabled(label) — anon/service callable boolean check
    - public.admin_set_cron_enabled(label, enabled) — admin-only toggle wrapper
    - admin_list_railway_cron_jobs now returns the `enabled` flag so the UI
      card knows the current state.

  Default state: enabled=true for every known cron label. Toggling to false
  makes cron-runner.sh skip the main curl (next tick logs status='skipped').
*/

BEGIN;

-- =============================================
-- 1. cron_enabled table + seed
-- =============================================
CREATE TABLE IF NOT EXISTS private.cron_enabled (
  label      text        PRIMARY KEY,
  enabled    boolean     NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE private.cron_enabled IS
  'Per-label on/off switch for Railway cron services. Read by cron-runner.sh
   on every tick via public.is_cron_enabled. Toggled by admin UI via
   public.admin_set_cron_enabled. Decoupled from Railway cronSchedule so
   the schedule stays in railway.toml but the kill switch lives in the DB.';

INSERT INTO private.cron_enabled (label) VALUES
  ('cron-tag-queue'),
  ('cron-scrape-sources'),
  ('cron-db-maintenance'),
  ('cron-cleanup-stale')
ON CONFLICT (label) DO NOTHING;

-- =============================================
-- 2. private.is_cron_enabled body
-- =============================================
CREATE OR REPLACE FUNCTION private.is_cron_enabled(p_label text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT enabled FROM private.cron_enabled WHERE label = p_label),
    true
  );
$$;

REVOKE EXECUTE ON FUNCTION private.is_cron_enabled(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.is_cron_enabled(text) TO service_role;

-- Public SECURITY INVOKER wrapper for PostgREST. service_role only — the
-- runner curls /rest/v1/rpc/is_cron_enabled with a Bearer sb_secret_* key.
CREATE OR REPLACE FUNCTION public.is_cron_enabled(p_label text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.is_cron_enabled(p_label);
$$;

REVOKE EXECUTE ON FUNCTION public.is_cron_enabled(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.is_cron_enabled(text) TO service_role;

-- =============================================
-- 3. admin_set_cron_enabled — admin-only toggle
-- =============================================
CREATE OR REPLACE FUNCTION private.admin_set_cron_enabled(p_label text, p_enabled boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO private.cron_enabled (label, enabled, updated_at)
  VALUES (p_label, p_enabled, now())
  ON CONFLICT (label) DO UPDATE
    SET enabled = EXCLUDED.enabled,
        updated_at = now();
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_set_cron_enabled(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_set_cron_enabled(text, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_set_cron_enabled(p_label text, p_enabled boolean)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.admin_set_cron_enabled(p_label, p_enabled);
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_cron_enabled(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_set_cron_enabled(text, boolean) TO authenticated;

-- =============================================
-- 4. Extend list_railway_cron_jobs with enabled
--    RETURNS TABLE shape grows — Postgres rejects ALTER to OUT param
--    shape, so DROP both wrapper + body before recreating.
-- =============================================
DROP FUNCTION IF EXISTS public.admin_list_railway_cron_jobs();
DROP FUNCTION IF EXISTS private.list_railway_cron_jobs();

CREATE FUNCTION private.list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  enabled             boolean,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH known AS (
    SELECT unnest(ARRAY[
      'cron-db-maintenance',
      'cron-tag-queue',
      'cron-scrape-sources',
      'cron-cleanup-stale'
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
$$;

REVOKE EXECUTE ON FUNCTION private.list_railway_cron_jobs() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_railway_cron_jobs() TO authenticated, service_role;

CREATE FUNCTION public.admin_list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  enabled             boolean,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_railway_cron_jobs();
$$;

REVOKE EXECUTE ON FUNCTION public.admin_list_railway_cron_jobs() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_list_railway_cron_jobs() TO authenticated;

COMMIT;
