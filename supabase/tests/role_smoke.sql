/*
  # Role smoke tests

  Verifies that:
    1.  anon can SELECT from public_events view
    2.  anon can SELECT from cities
    3.  anon can SELECT from tags
    4.  anon can SELECT from event_tag_queue_summary
    5.  anon can SELECT from source_scrape_queue_summary
    6.  anon gets 0 rows (not an error) from favorites (RLS filters, no exception)
    7.  anon can call public.events_enriched()
    8.  anon can call public.search_events_v2()
    9.  anon CANNOT call public.is_cron_enabled (expect 42501)
    10. authenticated can SELECT from events
    11. authenticated can SELECT from favorites (own rows via RLS, 0 rows fine)
    12. authenticated can call public.events_enriched()
    13. service_role (postgres context) can SELECT from events
    14. service_role can call public.is_cron_enabled()

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/role_smoke.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- ─── Seed a non-admin user ────────────────────────────────────────────────────
CREATE TEMP TABLE _rs_fx (k text PRIMARY KEY, v text);
INSERT INTO _rs_fx VALUES ('user_uid', gen_random_uuid()::text);

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT v::uuid, 'rs-user@test.local', 'authenticated', 'authenticated', now(),
       '00000000-0000-0000-0000-000000000000'
FROM _rs_fx WHERE k = 'user_uid';

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT v::uuid, 'rs-user@test.local', 'RS User', 'user'
FROM _rs_fx WHERE k = 'user_uid'
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, updated_at = now();

INSERT INTO public.user_access (user_id, is_enabled, enabled_at)
SELECT v::uuid, true, now()
FROM _rs_fx WHERE k = 'user_uid'
ON CONFLICT (user_id) DO UPDATE
  SET is_enabled = true, enabled_at = now(), disabled_at = NULL,
      access_expires_at = NULL, updated_at = now();

-- =============================================================================
-- ANON TESTS
-- =============================================================================

-- 1. anon can SELECT from public_events view
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM * FROM public.public_events LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'ANON_PUBLIC_EVENTS_OK';
END $$;

-- 2. anon can SELECT from cities
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM * FROM public.cities LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'ANON_CITIES_OK';
END $$;

-- 3. anon can SELECT from tags
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM * FROM public.tags LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'ANON_TAGS_OK';
END $$;

-- 4. anon can SELECT from event_tag_queue_summary
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM * FROM public.event_tag_queue_summary LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'ANON_TAG_QUEUE_SUMMARY_OK';
END $$;

-- 5. anon can SELECT from source_scrape_queue_summary
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM * FROM public.source_scrape_queue_summary LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'ANON_SCRAPE_QUEUE_SUMMARY_OK';
END $$;

-- 6. anon gets 0 rows from favorites (RLS filters silently, no exception)
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM * FROM public.favorites LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'ANON_FAVORITES_NO_EXCEPTION_OK';
END $$;

-- 7. anon can call public.events_enriched()
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.events_enriched();
  RESET ROLE;
  RAISE NOTICE 'ANON_EVENTS_ENRICHED_OK';
END $$;

-- 8. anon can call public.search_events_v2()
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.search_events_v2();
  RESET ROLE;
  RAISE NOTICE 'ANON_SEARCH_EVENTS_V2_OK';
END $$;

-- 9. anon CANNOT call public.is_cron_enabled
DO $$
DECLARE
  has_execute boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.is_cron_enabled(text)', 'EXECUTE')
  INTO has_execute;

  IF has_execute THEN
    RAISE EXCEPTION 'ANON_IS_CRON_ENABLED_FAIL: anon has EXECUTE on public.is_cron_enabled';
  END IF;

  RAISE NOTICE 'ANON_IS_CRON_ENABLED_DENIED_OK';
END $$;

-- =============================================================================
-- AUTHENTICATED TESTS
-- =============================================================================

-- 10. authenticated can SELECT from events
DO $$
DECLARE uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _rs_fx WHERE k = 'user_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  PERFORM * FROM public.events LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'AUTH_EVENTS_OK';
END $$;

-- 11. authenticated can SELECT from favorites (own rows, 0 rows is fine)
DO $$
DECLARE uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _rs_fx WHERE k = 'user_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  PERFORM * FROM public.favorites LIMIT 1;
  RESET ROLE;
  RAISE NOTICE 'AUTH_FAVORITES_OK';
END $$;

-- 12. authenticated can call public.events_enriched()
DO $$
DECLARE uid uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _rs_fx WHERE k = 'user_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  PERFORM public.events_enriched();
  RESET ROLE;
  RAISE NOTICE 'AUTH_EVENTS_ENRICHED_OK';
END $$;

-- =============================================================================
-- SERVICE_ROLE TESTS (postgres superuser context)
-- =============================================================================

-- 13. service_role can SELECT from events
DO $$
BEGIN
  -- Running as postgres/superuser mirrors service_role context
  PERFORM * FROM public.events LIMIT 1;
  RAISE NOTICE 'SERVICE_EVENTS_OK';
END $$;

-- 14. service_role can call public.is_cron_enabled()
DO $$
BEGIN
  PERFORM public.is_cron_enabled('cron-tag-queue');
  RAISE NOTICE 'SERVICE_IS_CRON_ENABLED_OK';
END $$;

ROLLBACK;

\echo 'role_smoke: PASS'
