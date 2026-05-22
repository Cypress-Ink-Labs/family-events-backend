/*
  # search_events full-text behavior

  Verifies keyword search uses event search_vector semantics while preserving
  short-keyword fallback behavior.

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/search_events_full_text.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('city_id', gen_random_uuid()::text),
  ('library_event', gen_random_uuid()::text),
  ('short_event', gen_random_uuid()::text),
  ('draft_event', gen_random_uuid()::text);

INSERT INTO public.cities (id, name, slug, is_active)
SELECT v::uuid, 'Search Test City', 'search-test-' || substr(v, 1, 8), true
FROM _fx WHERE k = 'city_id';

INSERT INTO public.events (id, title, description, start_datetime, status, city_id)
SELECT v::uuid,
       CASE k
         WHEN 'library_event' THEN 'Storytime At The Library'
         WHEN 'short_event' THEN 'LA Art Walk'
         ELSE 'Private Library Preview'
       END,
       CASE k
         WHEN 'library_event' THEN 'Families can enjoy books, crafts, and music together.'
         WHEN 'short_event' THEN 'Short keyword fallback fixture.'
         ELSE 'Drafts must not leak through published search.'
       END,
       CASE k
         WHEN 'library_event' THEN now() + interval '1 day'
         WHEN 'short_event' THEN now() + interval '2 days'
         ELSE now() + interval '3 days'
       END,
       CASE k WHEN 'draft_event' THEN 'draft' ELSE 'published' END,
       (SELECT v::uuid FROM _fx WHERE k = 'city_id')
FROM _fx WHERE k IN ('library_event', 'short_event', 'draft_event');

DO $$
DECLARE
  library_id uuid := (SELECT v::uuid FROM _fx WHERE k = 'library_event');
  short_id uuid := (SELECT v::uuid FROM _fx WHERE k = 'short_event');
  draft_id uuid := (SELECT v::uuid FROM _fx WHERE k = 'draft_event');
  n int;
BEGIN
  SELECT count(*) INTO n
  FROM public.search_events(p_keyword := 'library crafts')
  WHERE id = library_id;
  IF n <> 1 THEN
    RAISE EXCEPTION 'FULL_TEXT_FAIL: expected library event for keyword search, got %', n;
  END IF;

  SELECT count(*) INTO n
  FROM public.search_events(p_keyword := 'library')
  WHERE id = draft_id;
  IF n <> 0 THEN
    RAISE EXCEPTION 'DRAFT_FAIL: draft appeared in published keyword search';
  END IF;

  SELECT count(*) INTO n
  FROM public.search_events(p_keyword := 'LA')
  WHERE id = short_id;
  IF n <> 1 THEN
    RAISE EXCEPTION 'SHORT_KEYWORD_FAIL: expected short-keyword fallback match, got %', n;
  END IF;

  RAISE NOTICE 'SEARCH_EVENTS_OK';
END $$;

ROLLBACK;

\echo 'search_events_full_text: PASS'
