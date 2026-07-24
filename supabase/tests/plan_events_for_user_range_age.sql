/*
  CIL-031 — plan_events_for_user_range age scoring and half-open window.

  Run through `pnpm run db:test`; all fixtures live in a rolled-back transaction.
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v uuid NOT NULL DEFAULT gen_random_uuid());
INSERT INTO _fx (k) VALUES
  ('user'),
  ('lower_only'),
  ('upper_only'),
  ('bounded'),
  ('all_ages'),
  ('before_end'),
  ('at_end');

INSERT INTO public.events (id, title, status, start_datetime, age_min, age_max)
SELECT v,
       'CIL-031 ' || k,
       'published',
       CASE k
         WHEN 'before_end' THEN '2040-06-24 04:59:59+00'::timestamptz
         WHEN 'at_end' THEN '2040-06-24 05:00:00+00'::timestamptz
         ELSE '2040-06-21 15:00:00+00'::timestamptz
       END,
       CASE k WHEN 'lower_only' THEN 10 WHEN 'bounded' THEN 3 ELSE NULL END,
       CASE k WHEN 'upper_only' THEN 5 WHEN 'bounded' THEN 7 ELSE NULL END
FROM _fx
WHERE k <> 'user';

-- One-sided and bounded ranges must score against the bound that was violated;
-- both NULL bounds accept every age. The lower/upper examples are five years
-- outside the valid range, so their score is zero.
DO $$
DECLARE
  test_user uuid;
  lower_score numeric;
  upper_score numeric;
  bounded_score numeric;
  all_ages_score numeric;
BEGIN
  SELECT v INTO test_user FROM _fx WHERE k = 'user';

  SELECT age_score INTO lower_score
  FROM public.plan_events_for_user_range(
    test_user, '2040-06-21 00:00:00+00', '2040-06-22 00:00:00+00',
    NULL, NULL, NULL, 5, 'neutral', 100
  )
  WHERE event_id = (SELECT v FROM _fx WHERE k = 'lower_only');

  SELECT age_score INTO upper_score
  FROM public.plan_events_for_user_range(
    test_user, '2040-06-21 00:00:00+00', '2040-06-22 00:00:00+00',
    NULL, NULL, NULL, 10, 'neutral', 100
  )
  WHERE event_id = (SELECT v FROM _fx WHERE k = 'upper_only');

  SELECT age_score INTO bounded_score
  FROM public.plan_events_for_user_range(
    test_user, '2040-06-21 00:00:00+00', '2040-06-22 00:00:00+00',
    NULL, NULL, NULL, 5, 'neutral', 100
  )
  WHERE event_id = (SELECT v FROM _fx WHERE k = 'bounded');

  SELECT age_score INTO all_ages_score
  FROM public.plan_events_for_user_range(
    test_user, '2040-06-21 00:00:00+00', '2040-06-22 00:00:00+00',
    NULL, NULL, NULL, 5, 'neutral', 100
  )
  WHERE event_id = (SELECT v FROM _fx WHERE k = 'all_ages');

  IF lower_score <> 0.0 THEN RAISE EXCEPTION 'lower-bound-only score expected 0.0, got %', lower_score; END IF;
  IF upper_score <> 0.0 THEN RAISE EXCEPTION 'upper-bound-only score expected 0.0, got %', upper_score; END IF;
  IF bounded_score <> 1.0 THEN RAISE EXCEPTION 'bounded score expected 1.0, got %', bounded_score; END IF;
  IF all_ages_score <> 1.0 THEN RAISE EXCEPTION 'all-ages score expected 1.0, got %', all_ages_score; END IF;
END $$;

-- The date window is [from, to): one second before p_date_to is included and
-- an event exactly at p_date_to is excluded.
DO $$
DECLARE
  test_user uuid;
BEGIN
  SELECT v INTO test_user FROM _fx WHERE k = 'user';

  IF NOT EXISTS (
    SELECT 1
    FROM public.plan_events_for_user_range(
      test_user, '2040-06-21 00:00:00+00', '2040-06-24 05:00:00+00',
      NULL, NULL, NULL, 5, 'neutral', 100
    )
    WHERE event_id = (SELECT v FROM _fx WHERE k = 'before_end')
  ) THEN
    RAISE EXCEPTION 'event one second before p_date_to was excluded';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.plan_events_for_user_range(
      test_user, '2040-06-21 00:00:00+00', '2040-06-24 05:00:00+00',
      NULL, NULL, NULL, 5, 'neutral', 100
    )
    WHERE event_id = (SELECT v FROM _fx WHERE k = 'at_end')
  ) THEN
    RAISE EXCEPTION 'event exactly at p_date_to was included';
  END IF;
END $$;

ROLLBACK;

\echo 'plan_events_for_user_range_age: PASS'
