\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fixture_users (key text PRIMARY KEY, id uuid);
INSERT INTO _fixture_users (key, id)
VALUES
  ('admin_uid', gen_random_uuid()),
  ('user_uid', gen_random_uuid()),
  ('expired_admin_uid', gen_random_uuid());

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT
  id,
  CASE key
    WHEN 'admin_uid' THEN 'admin-events-rpc-admin@test.local'
    WHEN 'user_uid' THEN 'admin-events-rpc-user@test.local'
    WHEN 'expired_admin_uid' THEN 'admin-events-rpc-expired@test.local'
  END,
  'authenticated',
  'authenticated',
  now(),
  '00000000-0000-0000-0000-000000000000'
FROM _fixture_users
ON CONFLICT (id) DO UPDATE SET
aud = EXCLUDED.aud,
  role = EXCLUDED.role,
  email = EXCLUDED.email,
  email_confirmed_at = EXCLUDED.email_confirmed_at,
  updated_at = now();

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT
  id,
  CASE key
    WHEN 'admin_uid' THEN 'admin-events-rpc-admin@test.local'
    WHEN 'user_uid' THEN 'admin-events-rpc-user@test.local'
    WHEN 'expired_admin_uid' THEN 'admin-events-rpc-expired@test.local'
  END,
  CASE key
    WHEN 'admin_uid' THEN 'Admin User'
    WHEN 'expired_admin_uid' THEN 'Expired Admin'
    ELSE 'Normal User'
  END,
  CASE
    WHEN key = 'user_uid' THEN 'user'
    ELSE 'admin'
  END
FROM _fixture_users
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  display_name = EXCLUDED.display_name,
  role = EXCLUDED.role,
  updated_at = now();

INSERT INTO public.user_access (user_id, is_enabled, enabled_at, access_expires_at)
SELECT
  id,
  true,
  now(),
  CASE
    WHEN key = 'expired_admin_uid' THEN now() - interval '1 hour'
    ELSE NULL
  END
FROM _fixture_users
ON CONFLICT (user_id) DO UPDATE SET
  is_enabled = EXCLUDED.is_enabled,
  enabled_at = EXCLUDED.enabled_at,
  access_expires_at = EXCLUDED.access_expires_at,
  updated_at = now();

-- 1) Non-admin roles cannot run the list RPC
DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'user_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  BEGIN
    PERFORM public.admin_events_enriched();
    RESET ROLE;
    RAISE EXCEPTION 'NON_ADMIN_ALLOWED_EVENTS';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
  END;

  RAISE NOTICE 'NON_ADMIN_EVENTS_DENIED';
END $$;

DO $$
BEGIN
  IF has_function_privilege(
    'anon',
    'public.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,int,public.llm_event_review_status,public.llm_event_review_decision,boolean)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'ANON_ALLOWED_EVENTS';
  END IF;

  RAISE NOTICE 'ANON_EVENTS_DENIED';
END $$;

DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'user_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  BEGIN
    PERFORM public.admin_event_facets();
    RESET ROLE;
    RAISE EXCEPTION 'NON_ADMIN_ALLOWED_FACETS';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
  END;

  RAISE NOTICE 'NON_ADMIN_FACETS_DENIED';
END $$;

DO $$
BEGIN
  IF has_function_privilege(
    'anon',
    'public.admin_event_facets(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'ANON_ALLOWED_FACETS';
  END IF;

  RAISE NOTICE 'ANON_FACETS_DENIED';
END $$;

-- 2) Expired admin role is still denied
DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'expired_admin_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  BEGIN
    PERFORM public.admin_events_enriched();
    RESET ROLE;
    RAISE EXCEPTION 'EXPIRED_ADMIN_ALLOWED_EVENTS';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
  END;

  RAISE NOTICE 'EXPIRED_ADMIN_EVENTS_DENIED';
END $$;

DO $$
DECLARE
  uid uuid;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'expired_admin_uid';

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  BEGIN
    PERFORM public.admin_event_facets();
    RESET ROLE;
    RAISE EXCEPTION 'EXPIRED_ADMIN_ALLOWED_FACETS';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
  END;

  RAISE NOTICE 'EXPIRED_ADMIN_FACETS_DENIED';
END $$;

-- 3) Exact total_count should reflect total matching rows, not page size.
DO $$
DECLARE
  uid uuid;
  total bigint;
  rows bigint;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'admin_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  INSERT INTO public.events (id, title, status, start_datetime, created_at, updated_at)
  SELECT
    gen_random_uuid(),
    format('ADMIN RPC Count %s', g),
    'published',
    now() + interval '1 day',
    now() - (g || ' minutes')::interval,
    now() - (g || ' minutes')::interval
  FROM generate_series(1, 205) g;

  SELECT count(*) INTO rows FROM public.admin_events_enriched(p_keyword => 'ADMIN RPC Count', p_limit => 50);
  SELECT total_count INTO total FROM public.admin_events_enriched(p_keyword => 'ADMIN RPC Count', p_limit => 50) LIMIT 1;

  RESET ROLE;

  IF rows IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'COUNT_LIMIT_FAIL: expected 50 rows from first page, got %', rows;
  END IF;

  IF total IS DISTINCT FROM 205 THEN
    RAISE EXCEPTION 'COUNT_TOTAL_FAIL: expected total_count 205, got %', total;
  END IF;

  RAISE NOTICE 'TOTAL_COUNT_OK';
END $$;

-- 4) Keyset pagination returns disjoint pages in descending order.
DO $$
DECLARE
  uid uuid;
  after_created_at timestamptz;
  after_id uuid;
  first_count bigint;
  second_count bigint;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'admin_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  INSERT INTO public.events (id, title, status, start_datetime, created_at, updated_at)
  SELECT
    gen_random_uuid(),
    format('ADMIN RPC Cursor %s', g),
    'published',
    now() + interval '1 day',
    now() - (g || ' minutes')::interval,
    now() - (g || ' minutes')::interval
  FROM generate_series(1, 120) g;

  CREATE TEMP TABLE IF NOT EXISTS _admin_events_cursor_page_one AS
    SELECT id, created_at
    FROM public.admin_events_enriched(p_keyword => 'ADMIN RPC Cursor', p_limit => 50)
    ORDER BY created_at DESC, id DESC;

  CREATE TEMP TABLE IF NOT EXISTS _admin_events_cursor_page_two AS
    SELECT id, created_at
    FROM _admin_events_cursor_page_one
    WHERE false;

  TRUNCATE _admin_events_cursor_page_one;
  TRUNCATE _admin_events_cursor_page_two;

  INSERT INTO _admin_events_cursor_page_one
  SELECT id, created_at
  FROM public.admin_events_enriched(p_keyword => 'ADMIN RPC Cursor', p_limit => 50)
  ORDER BY created_at DESC, id DESC;

  SELECT created_at, id
  INTO after_created_at, after_id
  FROM _admin_events_cursor_page_one
  ORDER BY created_at DESC, id DESC
  OFFSET 49 LIMIT 1;

  INSERT INTO _admin_events_cursor_page_two
  SELECT id, created_at
  FROM public.admin_events_enriched(
    p_keyword => 'ADMIN RPC Cursor',
    p_limit => 50,
    p_after_created_at => after_created_at,
    p_after_id => after_id
  )
  ORDER BY created_at DESC, id DESC;

  SELECT count(*) INTO first_count FROM _admin_events_cursor_page_one;
  SELECT count(*) INTO second_count FROM _admin_events_cursor_page_two;

  IF first_count IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'CURSOR_FAIL: expected first page 50 rows, got %', first_count;
  END IF;

  IF second_count IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'CURSOR_FAIL: expected second page 50 rows, got %', second_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM _admin_events_cursor_page_one a
    JOIN _admin_events_cursor_page_two b USING (id)
  ) THEN
    RESET ROLE;
    RAISE EXCEPTION 'CURSOR_FAIL: overlap between pages';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM _admin_events_cursor_page_two
    WHERE (created_at, id) >= (after_created_at, after_id)
  ) THEN
    RESET ROLE;
    RAISE EXCEPTION 'CURSOR_FAIL: second page contains rows at or above cursor';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'CURSOR_OK';
END $$;

-- 5) Facets are grouped by city and status and match list keyword totals.
DO $$
DECLARE
  uid uuid;
  city_one uuid := gen_random_uuid();
  city_two uuid := gen_random_uuid();
  list_total bigint;
  facet_total bigint;
  city_one_draft bigint;
  city_one_published bigint;
  city_two_draft bigint;
  city_two_rejected bigint;
  unassigned_published bigint;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'admin_uid';

  INSERT INTO public.cities (id, name, slug, state, country, timezone, is_active, created_at)
  VALUES
    (city_one, 'Admin City One', 'admin-city-one', 'IL', 'US', 'America/Chicago', true, now()),
    (city_two, 'Admin City Two', 'admin-city-two', 'IL', 'US', 'America/Chicago', true, now())
  ON CONFLICT (id) DO UPDATE
    SET name = EXCLUDED.name;

  INSERT INTO public.events (id, city_id, title, status, start_datetime, created_at, updated_at)
  VALUES
    (gen_random_uuid(), city_one, 'ADMIN RPC Facet Seed', 'draft', now() + interval '1 day', now(), now()),
    (gen_random_uuid(), city_one, 'ADMIN RPC Facet Seed', 'published', now() + interval '1 day', now(), now()),
    (gen_random_uuid(), city_two, 'ADMIN RPC Facet Seed', 'draft', now() + interval '1 day', now(), now()),
    (gen_random_uuid(), NULL, 'ADMIN RPC Facet Seed', 'published', now() + interval '1 day', now(), now()),
    (gen_random_uuid(), city_two, 'ADMIN RPC Facet Seed', 'rejected', now() + interval '1 day', now(), now());

  SELECT id INTO uid FROM _fixture_users WHERE key = 'admin_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  SELECT COALESCE(SUM(count), 0) INTO facet_total
  FROM public.admin_event_facets('ADMIN RPC Facet Seed');

  SELECT total_count INTO list_total
  FROM public.admin_events_enriched(p_keyword => 'ADMIN RPC Facet Seed', p_limit => 200)
  LIMIT 1;

  SELECT COALESCE(SUM(count), 0)
  INTO city_one_draft
  FROM public.admin_event_facets('ADMIN RPC Facet Seed')
  WHERE city_id = city_one AND status = 'draft';

  SELECT COALESCE(SUM(count), 0)
  INTO city_one_published
  FROM public.admin_event_facets('ADMIN RPC Facet Seed')
  WHERE city_id = city_one AND status = 'published';

  SELECT COALESCE(SUM(count), 0)
  INTO city_two_draft
  FROM public.admin_event_facets('ADMIN RPC Facet Seed')
  WHERE city_id = city_two AND status = 'draft';

  SELECT COALESCE(SUM(count), 0)
  INTO city_two_rejected
  FROM public.admin_event_facets('ADMIN RPC Facet Seed')
  WHERE city_id = city_two AND status = 'rejected';

  SELECT COALESCE(SUM(count), 0)
  INTO unassigned_published
  FROM public.admin_event_facets('ADMIN RPC Facet Seed')
  WHERE city_id IS NULL AND status = 'published';

  RESET ROLE;

  IF facet_total <> 5 THEN
    RAISE EXCEPTION 'FACET_COUNT_FAIL: expected 5 rows across all facets, got %', facet_total;
  END IF;

  IF list_total IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION 'FACET_LIST_TOTAL_FAIL: list total_count expected 5, got %', list_total;
  END IF;

  IF city_one_draft <> 1 OR city_one_published <> 1 OR city_two_draft <> 1 OR city_two_rejected <> 1 OR unassigned_published <> 1 THEN
    RAISE EXCEPTION 'FACET_CELL_FAIL: (% , %, %, %, %)', city_one_draft, city_one_published, city_two_draft, city_two_rejected, unassigned_published;
  END IF;

  RAISE NOTICE 'FACETS_OK';
END $$;

-- 6) Keyword filtering is consistent between list and facet totals.
DO $$
DECLARE
  uid uuid;
  list_total bigint;
  facet_total bigint;
BEGIN
  SELECT id INTO uid FROM _fixture_users WHERE key = 'admin_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  INSERT INTO public.events (id, title, status, start_datetime, created_at, updated_at)
  SELECT
    gen_random_uuid(),
    format('ADMIN RPC Keyword Seed %s', g),
    CASE WHEN g % 2 = 0 THEN 'published' ELSE 'draft' END,
    now() + interval '1 day',
    now() - (g || ' minutes')::interval,
    now() - (g || ' minutes')::interval
  FROM generate_series(1, 12) g;

  SELECT total_count INTO list_total
  FROM public.admin_events_enriched(p_keyword => 'ADMIN RPC Keyword Seed', p_limit => 5)
  LIMIT 1;

  SELECT COALESCE(SUM(count), 0)
  INTO facet_total
  FROM public.admin_event_facets('ADMIN RPC Keyword Seed');

  RESET ROLE;

  IF list_total IS NULL OR list_total <> facet_total THEN
    RAISE EXCEPTION 'KEYWORD_SYNC_FAIL: list_total=% facet_total=%', list_total, facet_total;
  END IF;

  RAISE NOTICE 'KEYWORD_SYNC_OK';
END $$;

ROLLBACK;

\echo 'admin_events_rpc: PASS'
