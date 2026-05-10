/*
  # Saturday Plan RLS integration

  Verifies the security boundary for public event previews:
  - anon can read public.public_events
  - anon cannot read raw public.events rows

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/rls_public_events_view.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx_sat_plan (k text PRIMARY KEY, v text);
INSERT INTO _fx_sat_plan VALUES
  ('event_id', gen_random_uuid()::text),
  ('city_id', gen_random_uuid()::text);

INSERT INTO public.cities (id, name, slug, is_active)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'city_id'),
  'Saturday Plan Test City',
  'sat-plan-test-' || substr((SELECT v FROM _fx_sat_plan WHERE k = 'city_id'), 1, 8),
  true
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.events (
  id,
  title,
  description,
  start_datetime,
  end_datetime,
  venue_name,
  address,
  city_id,
  images,
  price,
  is_free,
  source_url,
  status
)
VALUES (
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'event_id'),
  'Saturday Plan Published Event',
  'Published event used by public view RLS test',
  now() + interval '1 day',
  now() + interval '1 day' + interval '1 hour',
  'Family Library',
  '123 Test Ave',
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'city_id'),
  '[]'::jsonb,
  0,
  true,
  'https://example.com/sat-plan-event',
  'published'
)
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
  event_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'event_id');
  view_visible boolean := false;
  raw_visible boolean := false;
BEGIN
  SET LOCAL role anon;

  SELECT EXISTS (
    SELECT 1
    FROM public.public_events
    WHERE id = event_uuid
  )
  INTO view_visible;

  SELECT EXISTS (
    SELECT 1
    FROM public.events
    WHERE id = event_uuid
  )
  INTO raw_visible;

  RESET role;

  IF NOT view_visible THEN
    RAISE EXCEPTION 'PUBLIC_EVENTS_VIEW_FAIL: anon could not read public.public_events';
  END IF;

  IF raw_visible THEN
    RAISE EXCEPTION 'PUBLIC_EVENTS_BOUNDARY_FAIL: anon can read raw public.events';
  END IF;

  RAISE NOTICE 'PUBLIC_EVENTS_BOUNDARY_OK: anon reads view, raw table blocked.';
END $$;

ROLLBACK;

\echo 'rls_public_events_view: PASS'
