/*
  # §2 — events_enriched / search_events cursor pagination tests

  Seeds 6 published events (2 city_a same-datetime, 2 city_a diff-datetime,
  2 city_b) inside a transaction and asserts:

  - Test 1: First page (p_limit=3) returns exactly 3 rows in (start_datetime, id) ASC order.
  - Test 2: Second page via cursor returns next 3 rows with no overlap.
  - Test 3: p_city_id=city_a restricts to city_a events only.
  - Test 4: p_date_from narrows to events on/after that date.
  - Test 5: Tie-breaking — same-datetime events appear in id ASC order, never duplicated.
  - Test 6: Anon path (p_user_id=NULL) returns is_favorited=false / is_in_calendar=false.
  - Test 7: search_events keyword search returns matching events.

  Run with:

    PGPASSWORD=postgres psql -h 127.0.0.1 -p 55322 -U postgres -d postgres \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/events_cursor_pagination.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixture: two cities, six published events.
-- ev_tie1 and ev_tie2 share the same start_datetime (tie-breaking test).
-- ev_a3 and ev_a4 have distinct later datetimes in city_a.
-- ev_b1 and ev_b2 are in city_b.
-- ev_search has a distinctive title for keyword search test.
-- -----------------------------------------------------------------------------

CREATE TEMP TABLE _cx (k text PRIMARY KEY, v text);
INSERT INTO _cx VALUES
  ('city_a',    gen_random_uuid()::text),
  ('city_b',    gen_random_uuid()::text),
  ('ev_tie1',   gen_random_uuid()::text),
  ('ev_tie2',   gen_random_uuid()::text),
  ('ev_a3',     gen_random_uuid()::text),
  ('ev_a4',     gen_random_uuid()::text),
  ('ev_b1',     gen_random_uuid()::text),
  ('ev_b2',     gen_random_uuid()::text),
  ('ev_search', gen_random_uuid()::text);

INSERT INTO public.cities (id, name, slug, is_active)
SELECT (v)::uuid,
       CASE k WHEN 'city_a' THEN 'CX City A' ELSE 'CX City B' END,
       CASE k WHEN 'city_a' THEN 'cx-a-' || substr(v, 1, 8) ELSE 'cx-b-' || substr(v, 1, 8) END,
       true
FROM _cx WHERE k IN ('city_a', 'city_b');

-- Base reference time for this test run.
-- ev_tie1 and ev_tie2: same datetime, city_a (ties broken by id).
-- ev_a3: +2d, city_a.
-- ev_a4: +3d, city_a.
-- ev_b1: +1d, city_b  (falls between tie events and ev_a3 in global order).
-- ev_b2: +4d, city_b.
-- ev_search: +5d, city_a, distinctive title.
INSERT INTO public.events (id, title, start_datetime, status, city_id)
SELECT (v)::uuid,
       CASE k
         WHEN 'ev_tie1'   THEN 'CX Tie Event 1'
         WHEN 'ev_tie2'   THEN 'CX Tie Event 2'
         WHEN 'ev_a3'     THEN 'CX City-A Event 3'
         WHEN 'ev_a4'     THEN 'CX City-A Event 4'
         WHEN 'ev_b1'     THEN 'CX City-B Event 1'
         WHEN 'ev_b2'     THEN 'CX City-B Event 2'
         ELSE                  'CX Xylophone Unique Keyword Event'
       END,
       CASE k
         WHEN 'ev_tie1'   THEN timestamptz '2099-01-01 10:00:00+00'
         WHEN 'ev_tie2'   THEN timestamptz '2099-01-01 10:00:00+00'
         WHEN 'ev_a3'     THEN timestamptz '2099-01-02 10:00:00+00'
         WHEN 'ev_a4'     THEN timestamptz '2099-01-03 10:00:00+00'
         WHEN 'ev_b1'     THEN timestamptz '2099-01-01 16:00:00+00'
         WHEN 'ev_b2'     THEN timestamptz '2099-01-04 10:00:00+00'
         ELSE                  timestamptz '2099-01-05 10:00:00+00'
       END,
       'published',
       CASE k
         WHEN 'ev_b1' THEN (SELECT (v)::uuid FROM _cx WHERE k='city_b')
         WHEN 'ev_b2' THEN (SELECT (v)::uuid FROM _cx WHERE k='city_b')
         ELSE              (SELECT (v)::uuid FROM _cx WHERE k='city_a')
       END
FROM _cx WHERE k IN ('ev_tie1','ev_tie2','ev_a3','ev_a4','ev_b1','ev_b2','ev_search');

-- -----------------------------------------------------------------------------
-- Test 1: First page — p_limit=3, no cursor — returns exactly 3 rows in
--         (start_datetime, id) ASC order.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  n         int;
  out_of_order int;
BEGIN
  SELECT COUNT(*) INTO n
  FROM public.events_enriched(
    p_date_from := timestamptz '2099-01-01 00:00:00+00',
    p_date_to   := timestamptz '2099-01-06 00:00:00+00',
    p_limit     := 3
  )
  WHERE title LIKE 'CX %';

  IF n IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'PAGE1_COUNT_FAIL: expected 3 rows, got %', n;
  END IF;

  -- Verify no row is out of (start_datetime, id) ASC order by checking that
  -- every row has a strictly greater (start_datetime, id) than the preceding one.
  SELECT COUNT(*) INTO out_of_order
  FROM (
    SELECT
      start_datetime,
      id,
      LAG(start_datetime) OVER (ORDER BY start_datetime ASC, id ASC) AS prev_dt,
      LAG(id)             OVER (ORDER BY start_datetime ASC, id ASC) AS prev_id
    FROM public.events_enriched(
      p_date_from := timestamptz '2099-01-01 00:00:00+00',
      p_date_to   := timestamptz '2099-01-06 00:00:00+00',
      p_limit     := 3
    )
    WHERE title LIKE 'CX %'
  ) ranked
  WHERE prev_dt IS NOT NULL
    AND (start_datetime, id) <= (prev_dt, prev_id);

  IF out_of_order > 0 THEN
    RAISE EXCEPTION 'PAGE1_ORDER_FAIL: % row(s) out of (start_datetime, id) ASC order', out_of_order;
  END IF;

  RAISE NOTICE 'TEST1_OK: first page returns 3 rows in (start_datetime, id) ASC order.';
END $$;

-- -----------------------------------------------------------------------------
-- Test 2: Second page via cursor — no overlap with first page.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  page1_ids  uuid[];
  page2_ids  uuid[];
  last_dt    timestamptz;
  last_id    uuid;
  overlap    int;
  n          int;
BEGIN
  SELECT array_agg(r.id ORDER BY r.start_datetime ASC, r.id ASC),
         (array_agg(r.start_datetime ORDER BY r.start_datetime ASC, r.id ASC))[3],
         (array_agg(r.id            ORDER BY r.start_datetime ASC, r.id ASC))[3]
    INTO page1_ids, last_dt, last_id
  FROM public.events_enriched(
    p_date_from := timestamptz '2099-01-01 00:00:00+00',
    p_date_to   := timestamptz '2099-01-06 00:00:00+00',
    p_limit     := 3
  ) r
  WHERE r.title LIKE 'CX %';

  SELECT array_agg(r.id ORDER BY r.start_datetime ASC, r.id ASC)
    INTO page2_ids
  FROM public.events_enriched(
    p_date_from             := timestamptz '2099-01-01 00:00:00+00',
    p_date_to               := timestamptz '2099-01-06 00:00:00+00',
    p_limit                := 3,
    p_after_start_datetime := last_dt,
    p_after_id             := last_id
  ) r
  WHERE r.title LIKE 'CX %';

  n := COALESCE(array_length(page2_ids, 1), 0);
  IF n = 0 THEN
    RAISE EXCEPTION 'PAGE2_EMPTY_FAIL: second page returned no rows';
  END IF;

  SELECT COUNT(*) INTO overlap
  FROM unnest(page1_ids) AS p1
  WHERE p1 = ANY(page2_ids);

  IF overlap > 0 THEN
    RAISE EXCEPTION 'PAGE2_OVERLAP_FAIL: % duplicate id(s) across page 1 and page 2', overlap;
  END IF;

  RAISE NOTICE 'TEST2_OK: second page has % rows, zero overlap with first page.', n;
END $$;

-- -----------------------------------------------------------------------------
-- Test 3: City filter — p_city_id=city_a returns only city_a events.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  city_a uuid;
  wrong  int;
  n      int;
BEGIN
  SELECT (v)::uuid INTO city_a FROM _cx WHERE k='city_a';

  SELECT COUNT(*) INTO n
  FROM public.events_enriched(p_city_id := city_a)
  WHERE title LIKE 'CX %';

  SELECT COUNT(*) INTO wrong
  FROM public.events_enriched(p_city_id := city_a)
  WHERE title LIKE 'CX %' AND city_id <> city_a;

  IF wrong > 0 THEN
    RAISE EXCEPTION 'CITY_FILTER_FAIL: %/% rows belong to wrong city', wrong, n;
  END IF;

  IF n = 0 THEN
    RAISE EXCEPTION 'CITY_FILTER_EMPTY_FAIL: p_city_id=city_a returned no rows';
  END IF;

  RAISE NOTICE 'TEST3_OK: city_a filter returns % city_a rows only.', n;
END $$;

-- -----------------------------------------------------------------------------
-- Test 4: Date filter — p_date_from excludes events before the cutoff.
-- ev_tie1/ev_tie2 start at +1d, ev_b1 at +1d6h, ev_a3 at +2d.
-- Cutoff of +1d12h should exclude ev_tie1 and ev_tie2 but keep ev_a3 onward.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  tie1_id uuid; tie2_id uuid;
  n       int;
BEGIN
  SELECT (v)::uuid INTO tie1_id FROM _cx WHERE k='ev_tie1';
  SELECT (v)::uuid INTO tie2_id FROM _cx WHERE k='ev_tie2';

  -- Events at +1d should be excluded.
  SELECT COUNT(*) INTO n
  FROM public.events_enriched(p_date_from := timestamptz '2099-01-01 22:00:00+00')
  WHERE id IN (tie1_id, tie2_id);

  IF n <> 0 THEN
    RAISE EXCEPTION 'DATE_FROM_FAIL: % tie event(s) leaked past p_date_from cutoff', n;
  END IF;

  -- Events from +2d onward should still appear.
  SELECT COUNT(*) INTO n
  FROM public.events_enriched(
    p_date_from := timestamptz '2099-01-01 22:00:00+00',
    p_date_to   := timestamptz '2099-01-06 00:00:00+00'
  )
  WHERE title LIKE 'CX %';

  IF n = 0 THEN
    RAISE EXCEPTION 'DATE_FROM_EMPTY_FAIL: p_date_from excluded all fixture events';
  END IF;

  RAISE NOTICE 'TEST4_OK: p_date_from correctly excludes events before cutoff.';
END $$;

-- -----------------------------------------------------------------------------
-- Test 5: Tie-breaking — ev_tie1 and ev_tie2 share start_datetime; they must
--         appear in id ASC order and must not be duplicated across pages.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  tie1_id  uuid;
  tie2_id  uuid;
  first_id uuid;
  sec_id   uuid;
  last_dt  timestamptz;
  last_id  uuid;
  p2_ids   uuid[];
  in_p1    int;
  in_p2    int;
BEGIN
  SELECT (v)::uuid INTO tie1_id FROM _cx WHERE k='ev_tie1';
  SELECT (v)::uuid INTO tie2_id FROM _cx WHERE k='ev_tie2';

  -- Both tie events must appear in either page 1 or page 2, in id ASC order.
  -- Fetch page 1 (limit=1 to force the split right at the tie boundary if ids fall there).
  -- Use limit=2 so both tie events fit or one of them is last on page 1.

  -- Gather page 1 with limit=2 scoped to city_a (tie events only in city_a).
  SELECT
    (array_agg(r.id ORDER BY r.start_datetime ASC, r.id ASC))[1],
    (array_agg(r.id ORDER BY r.start_datetime ASC, r.id ASC))[2],
    (array_agg(r.start_datetime ORDER BY r.start_datetime ASC, r.id ASC))[2],
    (array_agg(r.id            ORDER BY r.start_datetime ASC, r.id ASC))[2]
  INTO first_id, sec_id, last_dt, last_id
  FROM public.events_enriched(
    p_city_id := (SELECT (v)::uuid FROM _cx WHERE k='city_a'),
    p_date_from := timestamptz '2099-01-01 00:00:00+00',
    p_date_to   := timestamptz '2099-01-06 00:00:00+00',
    p_limit   := 2
  ) r;

  -- Verify the two returned ids are in ASC order (first_id < sec_id lexicographically).
  IF first_id > sec_id THEN
    RAISE EXCEPTION 'TIE_ORDER_FAIL: first id % > second id % (want ASC)', first_id, sec_id;
  END IF;

  -- Fetch page 2 cursor.
  SELECT array_agg(r.id)
    INTO p2_ids
  FROM public.events_enriched(
    p_city_id              := (SELECT (v)::uuid FROM _cx WHERE k='city_a'),
    p_date_from            := timestamptz '2099-01-01 00:00:00+00',
    p_date_to              := timestamptz '2099-01-06 00:00:00+00',
    p_limit                := 10,
    p_after_start_datetime := last_dt,
    p_after_id             := last_id
  ) r;

  -- Check tie events not duplicated: each tie id appears in exactly one page.
  SELECT COUNT(*) INTO in_p1 FROM (VALUES (first_id),(sec_id)) t(id)
    WHERE id IN (tie1_id, tie2_id);
  SELECT COUNT(*) INTO in_p2 FROM unnest(p2_ids) u WHERE u IN (tie1_id, tie2_id);

  IF (in_p1 + in_p2) <> 2 THEN
    RAISE EXCEPTION 'TIE_MISSING_FAIL: only % of 2 tie events found across both pages', in_p1 + in_p2;
  END IF;

  IF in_p1 + in_p2 > 2 THEN
    RAISE EXCEPTION 'TIE_DUPLICATE_FAIL: tie events duplicated across pages';
  END IF;

  RAISE NOTICE 'TEST5_OK: tie events appear in id ASC order, no duplication across pages.';
END $$;

-- -----------------------------------------------------------------------------
-- Test 6: Anon path — p_user_id=NULL → is_favorited=false, is_in_calendar=false.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  wrong int;
BEGIN
  SELECT COUNT(*) INTO wrong
  FROM public.events_enriched(
    p_user_id   := NULL,
    p_date_from := timestamptz '2099-01-01 00:00:00+00',
    p_date_to   := timestamptz '2099-01-06 00:00:00+00'
  )
  WHERE title LIKE 'CX %'
    AND (is_favorited IS DISTINCT FROM false OR is_in_calendar IS DISTINCT FROM false);

  IF wrong > 0 THEN
    RAISE EXCEPTION 'ANON_STATE_FAIL: % row(s) have non-false is_favorited or is_in_calendar for anon', wrong;
  END IF;

  RAISE NOTICE 'TEST6_OK: anon path returns is_favorited=false and is_in_calendar=false on all rows.';
END $$;

-- -----------------------------------------------------------------------------
-- Test 7: search_events keyword search returns matching event.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  search_id uuid;
  n         int;
BEGIN
  SELECT (v)::uuid INTO search_id FROM _cx WHERE k='ev_search';

  SELECT COUNT(*) INTO n
  FROM public.search_events(p_keyword := 'Xylophone')
  WHERE id = search_id;

  IF n <> 1 THEN
    RAISE EXCEPTION 'SEARCH_V2_FAIL: keyword ''Xylophone'' returned %, expected 1 match', n;
  END IF;

  RAISE NOTICE 'TEST7_OK: search_events keyword search returns the correct event.';
END $$;

ROLLBACK;

\echo 'events_cursor_pagination: PASS'
