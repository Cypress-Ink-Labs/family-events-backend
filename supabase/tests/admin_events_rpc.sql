/*
  # admin_events_enriched RPC security and behaviour

  Verifies that:
    1. anon cannot call public.admin_events_enriched (42501)
    2. authenticated non-admin cannot call it (42501)
    3. authenticated expired admin cannot call it (42501)
    4. enabled admin gets rows ordered by (created_at DESC, id DESC)
    5. p_status filter returns only matching rows
    6. total_count reflects the count of matching rows

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/admin_events_rpc.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('user_uid',           gen_random_uuid()::text),
  ('admin_uid',          gen_random_uuid()::text),
  ('expired_admin_uid',  gen_random_uuid()::text);

-- Auth users
INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT
  (v)::uuid,
  CASE k
    WHEN 'admin_uid'         THEN 'aer-admin@test.local'
    WHEN 'expired_admin_uid' THEN 'aer-expired@test.local'
    ELSE                          'aer-user@test.local'
  END,
  'authenticated',
  'authenticated',
  now(),
  '00000000-0000-0000-0000-000000000000'
FROM _fx;

-- Profiles
INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT
  (v)::uuid,
  CASE k
    WHEN 'admin_uid'         THEN 'aer-admin@test.local'
    WHEN 'expired_admin_uid' THEN 'aer-expired@test.local'
    ELSE                          'aer-user@test.local'
  END,
  CASE k
    WHEN 'admin_uid'         THEN 'AER Admin'
    WHEN 'expired_admin_uid' THEN 'AER Expired Admin'
    ELSE                          'AER User'
  END,
  CASE k
    WHEN 'user_uid' THEN 'user'
    ELSE                 'admin'
  END
FROM _fx
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, updated_at = now();

-- Access rows
INSERT INTO public.user_access (user_id, is_enabled, enabled_at, access_expires_at)
VALUES
  -- regular non-admin
  ((SELECT v::uuid FROM _fx WHERE k = 'user_uid'),          true,  now(), NULL),
  -- enabled admin
  ((SELECT v::uuid FROM _fx WHERE k = 'admin_uid'),         true,  now(), NULL),
  -- expired admin (access_expires_at in the past)
  ((SELECT v::uuid FROM _fx WHERE k = 'expired_admin_uid'), true,  now(), now() - interval '1 hour')
ON CONFLICT (user_id) DO UPDATE
  SET is_enabled       = EXCLUDED.is_enabled,
      enabled_at       = EXCLUDED.enabled_at,
      access_expires_at = EXCLUDED.access_expires_at,
      updated_at       = now();

-- ============================================================
-- 1. anon cannot call public.admin_events_enriched
-- ============================================================
DO $$
BEGIN
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.admin_events_enriched();
    RESET ROLE;
    RAISE EXCEPTION 'ANON_FAIL: anon was able to call admin_events_enriched';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'ANON_OK';
  END;
END $$;

-- ============================================================
-- 2. authenticated non-admin raises 42501
-- ============================================================
DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'user_uid';

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    PERFORM public.admin_events_enriched();
    RESET ROLE;
    RAISE EXCEPTION 'NON_ADMIN_FAIL: non-admin was able to call admin_events_enriched';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'NON_ADMIN_OK';
  END;
END $$;

-- ============================================================
-- 3. authenticated expired admin raises 42501
-- ============================================================
DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'expired_admin_uid';

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    PERFORM public.admin_events_enriched();
    RESET ROLE;
    RAISE EXCEPTION 'EXPIRED_ADMIN_FAIL: expired admin was able to call admin_events_enriched';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'EXPIRED_ADMIN_OK';
  END;
END $$;

-- ============================================================
-- 4. enabled admin gets rows ordered (created_at DESC, id DESC)
-- ============================================================
DO $$
DECLARE
  uid       uuid;
  city_id   uuid := gen_random_uuid();
  ev1_id    uuid := gen_random_uuid();
  ev2_id    uuid := gen_random_uuid();
  ev3_id    uuid := gen_random_uuid();
  prev_created timestamptz;
  prev_id      uuid;
  r         record;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  -- Insert 3 events with distinct created_at values
  INSERT INTO public.events (id, title, status, created_at, updated_at)
  VALUES
    (ev1_id, 'AER Event Oldest',  'published', now() - interval '3 hours', now()),
    (ev2_id, 'AER Event Middle',  'published', now() - interval '2 hours', now()),
    (ev3_id, 'AER Event Newest',  'published', now() - interval '1 hour',  now());

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  prev_created := 'infinity'::timestamptz;
  prev_id      := 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid;

  FOR r IN
    SELECT e.created_at, e.id
    FROM public.admin_events_enriched(p_keyword => 'AER Event') e
    ORDER BY e.created_at DESC, e.id DESC
  LOOP
    IF (r.created_at, r.id) >= (prev_created, prev_id) AND prev_created <> 'infinity'::timestamptz THEN
      RESET ROLE;
      RAISE EXCEPTION 'ORDER_FAIL: rows not in (created_at DESC, id DESC) order';
    END IF;
    prev_created := r.created_at;
    prev_id      := r.id;
  END LOOP;

  RESET ROLE;
  RAISE NOTICE 'ORDER_OK';
END $$;

-- ============================================================
-- 5. p_status filter returns only matching rows
-- ============================================================
DO $$
DECLARE
  uid        uuid;
  draft_cnt  bigint;
  pub_cnt    bigint;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  -- Seed 1 draft + 1 published with a unique keyword
  INSERT INTO public.events (id, title, status, created_at, updated_at)
  VALUES
    (gen_random_uuid(), 'AER Status Draft',     'draft',     now(), now()),
    (gen_random_uuid(), 'AER Status Published', 'published', now(), now());

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  SELECT count(*) INTO draft_cnt
  FROM public.admin_events_enriched(p_status => 'draft', p_keyword => 'AER Status');

  SELECT count(*) INTO pub_cnt
  FROM public.admin_events_enriched(p_status => 'published', p_keyword => 'AER Status');

  RESET ROLE;

  IF draft_cnt <> 1 THEN
    RAISE EXCEPTION 'STATUS_DRAFT_FAIL: expected 1 draft row, got %', draft_cnt;
  END IF;
  IF pub_cnt <> 1 THEN
    RAISE EXCEPTION 'STATUS_PUBLISHED_FAIL: expected 1 published row, got %', pub_cnt;
  END IF;

  RAISE NOTICE 'STATUS_FILTER_OK';
END $$;

-- ============================================================
-- 6. total_count reflects count of matching rows
-- ============================================================
DO $$
DECLARE
  uid         uuid;
  total       bigint;
  row_count   bigint;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'admin_uid';

  -- Seed 3 events with a unique keyword
  INSERT INTO public.events (id, title, status, created_at, updated_at)
  VALUES
    (gen_random_uuid(), 'AER TotalCount Alpha',   'published', now(), now()),
    (gen_random_uuid(), 'AER TotalCount Beta',    'published', now(), now()),
    (gen_random_uuid(), 'AER TotalCount Gamma',   'published', now(), now());

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  SELECT e.total_count, count(*) OVER ()
  INTO total, row_count
  FROM public.admin_events_enriched(p_keyword => 'AER TotalCount') e
  LIMIT 1;

  RESET ROLE;

  IF total IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'TOTAL_COUNT_FAIL: expected 3, got %', total;
  END IF;

  RAISE NOTICE 'TOTAL_COUNT_OK';
END $$;

ROLLBACK;

\echo 'admin_events_rpc: PASS'
