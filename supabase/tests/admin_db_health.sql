/*
  # admin_db_health_snapshot security

  Verifies that:
    1. anon cannot call public.admin_db_health_snapshot — expect 42501
    2. authenticated non-admin cannot call it — expect 42501
    3. enabled admin can call it and result is a JSONB object (not null)
    4. result has expected keys: 'tag_queue_by_status', 'source_queue_by_status',
       'source_runs_stuck_running', 'snapshot_at'

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/admin_db_health.sql
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
       CASE k WHEN 'admin_uid' THEN 'health-admin@test.local' ELSE 'health-user@test.local' END,
       'authenticated',
       'authenticated',
       now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k IN ('user_uid', 'admin_uid');

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT (v)::uuid,
       CASE k WHEN 'admin_uid' THEN 'health-admin@test.local' ELSE 'health-user@test.local' END,
       CASE k WHEN 'admin_uid' THEN 'Health Admin' ELSE 'Health User' END,
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
-- 1. anon cannot call public.admin_db_health_snapshot
-- =============================================
DO $$
DECLARE
  has_execute boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.admin_db_health_snapshot()', 'EXECUTE')
  INTO has_execute;

  IF has_execute THEN
    RAISE EXCEPTION 'ANON_HEALTH_FAIL: anon has EXECUTE on public.admin_db_health_snapshot';
  END IF;

  RAISE NOTICE 'ANON_HEALTH_OK';
END $$;

-- =============================================
-- 2. authenticated non-admin cannot call it
-- =============================================
DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'user_uid';

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    PERFORM public.admin_db_health_snapshot();
    RESET ROLE;
    RAISE EXCEPTION 'NON_ADMIN_HEALTH_FAIL: non-admin was able to call admin_db_health_snapshot';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'NON_ADMIN_HEALTH_OK';
  END;
END $$;

-- =============================================
-- 3. enabled admin can call it and result is not null
-- =============================================
DO $$
DECLARE
  uid    uuid;
  result jsonb;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  SELECT public.admin_db_health_snapshot() INTO result;
  RESET ROLE;

  IF result IS NULL THEN
    RAISE EXCEPTION 'ADMIN_HEALTH_NULL_FAIL: admin_db_health_snapshot returned null';
  END IF;

  IF jsonb_typeof(result) <> 'object' THEN
    RAISE EXCEPTION 'ADMIN_HEALTH_TYPE_FAIL: expected object, got %', jsonb_typeof(result);
  END IF;

  RAISE NOTICE 'ADMIN_HEALTH_OK';
END $$;

-- =============================================
-- 4. result has expected keys
-- =============================================
DO $$
DECLARE
  uid    uuid;
  result jsonb;
  key    text;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  SELECT public.admin_db_health_snapshot() INTO result;
  RESET ROLE;

  FOREACH key IN ARRAY ARRAY[
    'tag_queue_by_status',
    'source_queue_by_status',
    'source_runs_stuck_running',
    'snapshot_at'
  ] LOOP
    IF NOT (result ? key) THEN
      RAISE EXCEPTION 'ADMIN_HEALTH_KEY_FAIL: result missing key "%"', key;
    END IF;
  END LOOP;

  RAISE NOTICE 'ADMIN_HEALTH_KEYS_OK';
END $$;

ROLLBACK;

\echo 'admin_db_health: PASS'
