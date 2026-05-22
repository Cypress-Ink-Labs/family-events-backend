/*
  # Cron toggle security

  Verifies that:
    1. anon cannot call public.is_cron_enabled
    2. service_role (postgres context) CAN call public.is_cron_enabled
    3. authenticated non-admin cannot call public.admin_set_cron_enabled
    4. enabled admin CAN toggle a cron label off and on
    5. public.admin_list_railway_cron_jobs returns the enabled column

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/cron_toggle.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('user_uid',  gen_random_uuid()::text),
  ('admin_uid', gen_random_uuid()::text);

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT (v)::uuid,
       CASE k WHEN 'admin_uid' THEN 'toggle-admin@test.local' ELSE 'toggle-user@test.local' END,
       'authenticated',
       'authenticated',
       now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k IN ('user_uid', 'admin_uid');

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT (v)::uuid,
       CASE k WHEN 'admin_uid' THEN 'toggle-admin@test.local' ELSE 'toggle-user@test.local' END,
       CASE k WHEN 'admin_uid' THEN 'Toggle Admin' ELSE 'Toggle User' END,
       CASE k WHEN 'admin_uid' THEN 'admin' ELSE 'user' END
FROM _fx WHERE k IN ('user_uid', 'admin_uid')
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, updated_at = now();

INSERT INTO public.user_access (user_id, is_enabled, enabled_at)
SELECT (v)::uuid, true, now()
FROM _fx WHERE k IN ('user_uid', 'admin_uid')
ON CONFLICT (user_id) DO UPDATE
SET is_enabled = true,
    enabled_at = now(),
    disabled_at = NULL,
    access_expires_at = NULL,
    updated_at = now();

-- =============================================
-- 1. anon cannot call public.is_cron_enabled
-- =============================================
DO $$
BEGIN
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.is_cron_enabled('cron-tag-queue');
    RESET ROLE;
    RAISE EXCEPTION 'ANON_IS_ENABLED_FAIL: anon was able to call is_cron_enabled';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'ANON_IS_ENABLED_OK';
  END;
END $$;

-- =============================================
-- 2. service_role (postgres context) CAN call public.is_cron_enabled
-- =============================================
DO $$
DECLARE
  result boolean;
BEGIN
  -- Running as postgres/superuser which has all privileges — mirrors service_role context
  SELECT public.is_cron_enabled('cron-tag-queue') INTO result;

  IF result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'SERVICE_IS_ENABLED_FAIL: expected true for cron-tag-queue, got %', result;
  END IF;

  RAISE NOTICE 'SERVICE_IS_ENABLED_OK';
END $$;

-- =============================================
-- 3. authenticated non-admin cannot call public.admin_set_cron_enabled
-- =============================================
DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'user_uid';

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    PERFORM public.admin_set_cron_enabled('cron-tag-queue', false);
    RESET ROLE;
    RAISE EXCEPTION 'NON_ADMIN_TOGGLE_FAIL: non-admin was able to toggle cron';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'NON_ADMIN_TOGGLE_OK';
  END;
END $$;

-- =============================================
-- 4. enabled admin CAN toggle cron-tag-queue off
-- =============================================
DO $$
DECLARE
  uid    uuid;
  result boolean;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  -- Toggle off as admin
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  PERFORM public.admin_set_cron_enabled('cron-tag-queue', false);
  RESET ROLE;

  -- Verify as postgres (service_role context)
  SELECT public.is_cron_enabled('cron-tag-queue') INTO result;

  IF result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'ADMIN_TOGGLE_OFF_FAIL: expected false for cron-tag-queue after disable, got %', result;
  END IF;

  RAISE NOTICE 'ADMIN_TOGGLE_OFF_OK';
END $$;

-- =============================================
-- 5. admin can toggle cron-tag-queue back on
-- =============================================
DO $$
DECLARE
  uid    uuid;
  result boolean;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  -- Toggle on as admin
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  PERFORM public.admin_set_cron_enabled('cron-tag-queue', true);
  RESET ROLE;

  -- Verify as postgres (service_role context)
  SELECT public.is_cron_enabled('cron-tag-queue') INTO result;

  IF result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'ADMIN_TOGGLE_ON_FAIL: expected true for cron-tag-queue after re-enable, got %', result;
  END IF;

  RAISE NOTICE 'ADMIN_TOGGLE_ON_OK';
END $$;

-- =============================================
-- 6. admin_list_railway_cron_jobs returns enabled column
-- =============================================
DO $$
DECLARE
  uid     uuid;
  enabled boolean;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  SELECT j.enabled INTO enabled
  FROM public.admin_list_railway_cron_jobs() j
  WHERE j.label = 'cron-tag-queue';
  RESET ROLE;

  IF enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'ADMIN_LIST_ENABLED_FAIL: expected enabled=true for cron-tag-queue, got %', enabled;
  END IF;

  RAISE NOTICE 'ADMIN_LIST_ENABLED_OK';
END $$;

ROLLBACK;

\echo 'cron_toggle: PASS'
