/*
  # Cron RPC security

  Verifies operational cron RPCs are limited to enabled admins for reads and
  service_role for writes.

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/cron_rpc_security.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('user_uid', gen_random_uuid()::text),
  ('admin_uid', gen_random_uuid()::text);

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT (v)::uuid,
       CASE k WHEN 'admin_uid' THEN 'cron-admin@test.local' ELSE 'cron-user@test.local' END,
       'authenticated',
       'authenticated',
       now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k IN ('user_uid', 'admin_uid');

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT (v)::uuid,
       CASE k WHEN 'admin_uid' THEN 'cron-admin@test.local' ELSE 'cron-user@test.local' END,
       CASE k WHEN 'admin_uid' THEN 'Cron Admin' ELSE 'Cron User' END,
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

DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'user_uid';

  BEGIN
    SET LOCAL role authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    PERFORM public.admin_list_railway_cron_jobs();
    RESET role;
    RAISE EXCEPTION 'NON_ADMIN_LIST_FAIL: non-admin read cron jobs';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET role;
      RAISE NOTICE 'NON_ADMIN_LIST_OK';
  END;

  BEGIN
    SET LOCAL role authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    PERFORM public.admin_railway_cron_run_history(NULL, 1);
    RESET role;
    RAISE EXCEPTION 'NON_ADMIN_HISTORY_FAIL: non-admin read cron history';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET role;
      RAISE NOTICE 'NON_ADMIN_HISTORY_OK';
  END;

  IF has_function_privilege(
    'authenticated',
    'public.log_railway_cron_run(text,text,integer,integer,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'NON_ADMIN_LOG_FAIL: authenticated user can execute cron log RPC';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.log_railway_cron_run(text,text,integer,integer,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'ANON_LOG_FAIL: anon user can execute cron log RPC';
  END IF;

  -- The EXECUTE grant on private.list_railway_cron_jobs() to authenticated exists (needed by
  -- the SECURITY INVOKER public wrapper), but the function body enforces the admin check.
  -- Verify that calling the public wrapper as non-admin raises 42501 rather than succeeding.
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    PERFORM public.admin_list_railway_cron_jobs();
    RESET ROLE;
    RAISE EXCEPTION 'PRIVATE_LIST_FAIL: non-admin authenticated user could list cron jobs';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
  END;

  IF has_function_privilege(
    'authenticated',
    'private.railway_cron_run_history(text,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PRIVATE_HISTORY_FAIL: authenticated user can execute private cron history RPC';
  END IF;

  IF has_function_privilege(
    'authenticated',
    'private.log_railway_cron_run(text,text,integer,integer,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PRIVATE_LOG_FAIL: authenticated user can execute private cron log RPC';
  END IF;

  RAISE NOTICE 'NON_ADMIN_LOG_OK';
END $$;

DO $$
DECLARE
  uid uuid;
  labels text[];
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  SELECT array_agg(label ORDER BY label) INTO labels
  FROM public.admin_list_railway_cron_jobs();
  RESET role;

  IF NOT labels @> ARRAY[
    'cron-cleanup-stale',
    'cron-db-maintenance',
    'cron-scrape-sources',
    'cron-tag-queue'
  ]::text[] THEN
    RAISE EXCEPTION 'ADMIN_LIST_FAIL: missing expected cron labels: %', labels;
  END IF;

  RAISE NOTICE 'ADMIN_LIST_OK';
END $$;

DO $$
BEGIN
  SET LOCAL role service_role;
  PERFORM public.log_railway_cron_run('cron-security-test', 'succeeded', 200, 1, 'ok');
  RESET role;

  IF NOT EXISTS (
    SELECT 1
    FROM private.railway_cron_runs
    WHERE label = 'cron-security-test'
      AND status = 'succeeded'
  ) THEN
    RAISE EXCEPTION 'SERVICE_LOG_FAIL: service_role log row missing';
  END IF;

  RAISE NOTICE 'SERVICE_LOG_OK';
END $$;

ROLLBACK;

\echo 'cron_rpc_security: PASS'
