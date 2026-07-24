/*
  CIL-035 — plan_events_for_user_range hydrated display fields and grants.

  Run through scripts/test.sh; fixtures live in a rolled-back transaction.
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v uuid NOT NULL DEFAULT gen_random_uuid());
INSERT INTO _fx (k) VALUES ('user'), ('event');

INSERT INTO public.events (
  id, title, status, start_datetime, venue_name, address, is_free, price, images
)
SELECT
  v,
  'CIL-035 Hydrated Event',
  'published',
  '2041-06-21 15:00:00+00'::timestamptz,
  'CIL-035 Venue',
  '123 Test Street',
  false,
  12.50,
  '["https://example.test/event.jpg"]'::jsonb
FROM _fx
WHERE k = 'event';

DO $$
DECLARE
  test_user uuid;
  expected_event uuid;
  row_title text;
  row_venue text;
  row_address text;
  row_is_free boolean;
  row_price numeric(10,2);
  row_images jsonb;
BEGIN
  SELECT v INTO test_user FROM _fx WHERE k = 'user';
  SELECT v INTO expected_event FROM _fx WHERE k = 'event';

  SELECT title, venue_name, address, is_free, price, images
  INTO row_title, row_venue, row_address, row_is_free, row_price, row_images
  FROM public.plan_events_for_user_range(
    test_user, '2041-06-21 00:00:00+00', '2041-06-22 00:00:00+00',
    NULL, NULL, NULL, NULL, 'neutral', 100
  )
  WHERE event_id = expected_event;

  IF row_title <> 'CIL-035 Hydrated Event' THEN
    RAISE EXCEPTION 'expected hydrated title, got %', row_title;
  END IF;
  IF row_venue <> 'CIL-035 Venue' OR row_address <> '123 Test Street' THEN
    RAISE EXCEPTION 'expected hydrated venue/address, got % / %', row_venue, row_address;
  END IF;
  IF row_is_free IS DISTINCT FROM false OR row_price <> 12.50 THEN
    RAISE EXCEPTION 'expected hydrated pricing fields, got % / %', row_is_free, row_price;
  END IF;
  IF jsonb_typeof(row_images) <> 'array'
     OR row_images ->> 0 <> 'https://example.test/event.jpg' THEN
    RAISE EXCEPTION 'expected hydrated images array, got %', row_images;
  END IF;
END $$;

DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'public.plan_events_for_user_range(uuid,timestamp with time zone,timestamp with time zone,uuid[],double precision,double precision,integer,text,integer)'::regprocedure,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated must not execute plan_events_for_user_range';
  END IF;
END $$;

ROLLBACK;

\echo 'plan_events_for_user_range_hydrated: PASS'
