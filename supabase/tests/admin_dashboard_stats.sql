/*
  # admin_dashboard_stats security + shape

  Verifies that:
    1. anon has no EXECUTE on public.admin_dashboard_stats — expect no privilege
    2. authenticated non-admin cannot call it — expect 42501
    3. enabled admin can call it and result is a JSONB object (not null)
    4. result has expected keys: 'total_events', 'draft_events',
       'published_events', 'ai_confidence', 'sources', 'dead_letters',
       'generated_at'
    5. dead_letters object has tag_queue/source_queue counts

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/admin_dashboard_stats.sql
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
       CASE k WHEN 'admin_uid' THEN 'stats-admin@test.local' ELSE 'stats-user@test.local' END,
       'authenticated',
       'authenticated',
       now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k IN ('user_uid', 'admin_uid');

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT (v)::uuid,
       CASE k WHEN 'admin_uid' THEN 'stats-admin@test.local' ELSE 'stats-user@test.local' END,
       CASE k WHEN 'admin_uid' THEN 'Stats Admin' ELSE 'Stats User' END,
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
-- 1. anon has no EXECUTE on public.admin_dashboard_stats
-- =============================================
DO $$
DECLARE
  has_execute boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.admin_dashboard_stats()', 'EXECUTE')
  INTO has_execute;

  IF has_execute THEN
    RAISE EXCEPTION 'ANON_STATS_FAIL: anon has EXECUTE on public.admin_dashboard_stats';
  END IF;

  RAISE NOTICE 'ANON_STATS_OK';
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
    PERFORM public.admin_dashboard_stats();
    RESET ROLE;
    RAISE EXCEPTION 'NON_ADMIN_STATS_FAIL: non-admin was able to call admin_dashboard_stats';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'NON_ADMIN_STATS_OK';
  END;
END $$;

-- =============================================
-- 3. enabled admin can call it and result is a jsonb object
-- =============================================
DO $$
DECLARE
  uid    uuid;
  result jsonb;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  SELECT public.admin_dashboard_stats() INTO result;
  RESET ROLE;

  IF result IS NULL THEN
    RAISE EXCEPTION 'ADMIN_STATS_NULL_FAIL: admin_dashboard_stats returned null';
  END IF;

  IF jsonb_typeof(result) <> 'object' THEN
    RAISE EXCEPTION 'ADMIN_STATS_TYPE_FAIL: expected object, got %', jsonb_typeof(result);
  END IF;

  RAISE NOTICE 'ADMIN_STATS_OK';
END $$;

-- =============================================
-- 4. result has expected top-level keys
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
  SELECT public.admin_dashboard_stats() INTO result;
  RESET ROLE;

  FOREACH key IN ARRAY ARRAY[
    'total_events',
    'draft_events',
    'published_events',
    'ai_confidence',
    'sources',
    'dead_letters',
    'generated_at'
  ] LOOP
    IF NOT (result ? key) THEN
      RAISE EXCEPTION 'ADMIN_STATS_KEY_FAIL: result missing key "%"', key;
    END IF;
  END LOOP;

  RAISE NOTICE 'ADMIN_STATS_KEYS_OK';
END $$;

-- =============================================
-- 5. dead_letters has queue count keys and numeric counts
-- =============================================
DO $$
DECLARE
  uid    uuid;
  result jsonb;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  SELECT public.admin_dashboard_stats() INTO result;
  RESET ROLE;

  IF NOT (result->'dead_letters' ? 'tag_queue')
     OR NOT (result->'dead_letters' ? 'source_queue') THEN
    RAISE EXCEPTION 'ADMIN_STATS_DEAD_FAIL: dead_letters missing queue keys';
  END IF;

  IF jsonb_typeof(result->'dead_letters'->'tag_queue') <> 'number'
     OR jsonb_typeof(result->'dead_letters'->'source_queue') <> 'number' THEN
    RAISE EXCEPTION 'ADMIN_STATS_DEAD_TYPE_FAIL: dead-letter counts are not numbers';
  END IF;

  RAISE NOTICE 'ADMIN_STATS_DEAD_OK';
END $$;

ROLLBACK;

\echo 'admin_dashboard_stats: PASS'
