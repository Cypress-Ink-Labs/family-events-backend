/*
  # H3 — anon read of published content (public view + cities)

  Verifies the Saturday Plan public boundary:
  - anon can see published events via public.public_events
  - anon can read published raw public.events rows, matching the
    security-invoker public_events policy
  - anon cannot read draft raw public.events rows
  - anon can see active cities; anon cannot see inactive cities

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/rls_anon_read.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixture: published + draft events, active + inactive cities.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('pub_event', gen_random_uuid()::text),
  ('draft_event', gen_random_uuid()::text),
  ('active_city', gen_random_uuid()::text),
  ('inactive_city', gen_random_uuid()::text);

INSERT INTO public.cities (id, name, slug, is_active)
SELECT (v)::uuid,
       CASE k WHEN 'active_city' THEN 'H3 Active City' ELSE 'H3 Inactive City' END,
       CASE k WHEN 'active_city' THEN 'h3-active-' || substr(v, 1, 8) ELSE 'h3-inactive-' || substr(v, 1, 8) END,
       (k = 'active_city')
FROM _fx WHERE k IN ('active_city', 'inactive_city');

INSERT INTO public.events (id, title, start_datetime, status)
SELECT (v)::uuid,
       CASE k WHEN 'pub_event' THEN 'H3 Published' ELSE 'H3 Draft' END,
       now() + interval '1 day',
       CASE k WHEN 'pub_event' THEN 'published' ELSE 'draft' END
FROM _fx WHERE k IN ('pub_event', 'draft_event');

-- -----------------------------------------------------------------------------
-- Anon: sees published data via public view, not raw table.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  pub_id uuid;
  draft_id uuid;
  pub_visible_in_view boolean;
  draft_visible_in_view boolean;
  raw_pub_visible boolean;
  raw_draft_visible boolean;
BEGIN
  SELECT (v)::uuid INTO pub_id FROM _fx WHERE k='pub_event';
  SELECT (v)::uuid INTO draft_id FROM _fx WHERE k='draft_event';

  SET LOCAL role anon;
  SELECT EXISTS (SELECT 1 FROM public.public_events WHERE id = pub_id) INTO pub_visible_in_view;
  SELECT EXISTS (SELECT 1 FROM public.public_events WHERE id = draft_id) INTO draft_visible_in_view;
  SELECT EXISTS (SELECT 1 FROM public.events WHERE id = pub_id) INTO raw_pub_visible;
  SELECT EXISTS (SELECT 1 FROM public.events WHERE id = draft_id) INTO raw_draft_visible;
  RESET role;

  IF NOT pub_visible_in_view THEN
    RAISE EXCEPTION 'PUBLIC_VIEW_PUB_FAIL: anon cannot see published event in public view';
  END IF;
  IF draft_visible_in_view THEN
    RAISE EXCEPTION 'PUBLIC_VIEW_DRAFT_FAIL: anon can see draft event in public view';
  END IF;
  IF NOT raw_pub_visible THEN
    RAISE EXCEPTION 'RAW_EVENTS_PUB_FAIL: anon cannot read published raw event';
  END IF;
  IF raw_draft_visible THEN
    RAISE EXCEPTION 'RAW_EVENTS_DRAFT_FAIL: anon can read draft raw event';
  END IF;
  RAISE NOTICE 'PUBLIC_VIEW_OK: anon sees published via view/raw table; draft rows blocked.';
END $$;

-- -----------------------------------------------------------------------------
-- Anon: sees only active cities.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  active_id uuid;
  inactive_id uuid;
  active_visible boolean;
  inactive_visible boolean;
BEGIN
  SELECT (v)::uuid INTO active_id FROM _fx WHERE k='active_city';
  SELECT (v)::uuid INTO inactive_id FROM _fx WHERE k='inactive_city';

  SET LOCAL role anon;
  SELECT EXISTS (SELECT 1 FROM public.cities WHERE id = active_id) INTO active_visible;
  SELECT EXISTS (SELECT 1 FROM public.cities WHERE id = inactive_id) INTO inactive_visible;
  RESET role;

  IF NOT active_visible THEN
    RAISE EXCEPTION 'CITIES_ACTIVE_FAIL: anon cannot see active city';
  END IF;
  IF inactive_visible THEN
    RAISE EXCEPTION 'CITIES_INACTIVE_FAIL: anon can see inactive city';
  END IF;
  RAISE NOTICE 'CITIES_OK: anon sees active, not inactive.';
END $$;

-- -----------------------------------------------------------------------------
-- Anon: cannot INSERT events (no INSERT policy for anon).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  err_code text;
BEGIN
  BEGIN
    SET LOCAL role anon;
    INSERT INTO public.events (title, start_datetime, status)
    VALUES ('anon insert attempt', now() + interval '1 day', 'draft');
    RESET role;
    RAISE EXCEPTION 'EVENTS_INSERT_FAIL: anon was able to INSERT an event';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET role;
      RAISE NOTICE 'EVENTS_INSERT_OK: anon blocked from INSERT.';
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err_code = RETURNED_SQLSTATE;
      RESET role;
      IF err_code IN ('42501', '23514') THEN
        RAISE NOTICE 'EVENTS_INSERT_OK: anon blocked from INSERT (%).', err_code;
      ELSE
        RAISE EXCEPTION 'EVENTS_INSERT_FAIL: unexpected SQLSTATE % (%)', err_code, SQLERRM;
      END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- Admin bypass sanity: seeded local admin can still read drafts.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  admin_uid uuid := '11111111-1111-4111-8111-111111111111';
  draft_id uuid;
  draft_visible boolean;
BEGIN
  SELECT (v)::uuid INTO draft_id FROM _fx WHERE k='draft_event';
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', admin_uid::text, true);

  SELECT EXISTS (SELECT 1 FROM public.events WHERE id = draft_id) INTO draft_visible;
  RESET role;

  IF NOT draft_visible THEN
    RAISE EXCEPTION 'ADMIN_FAIL: seeded admin cannot see draft event';
  END IF;
  RAISE NOTICE 'ADMIN_OK: seeded admin sees draft via is_admin() bypass.';
END $$;

ROLLBACK;

\echo 'rls_anon_read: PASS'
