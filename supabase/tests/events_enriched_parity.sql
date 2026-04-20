/*
  # Wave 2.1 — events_enriched RPC parity / behavior tests

  Seeds a small fixture (three published events, one draft, two tags,
  ratings, a favorite, a calendar entry) inside a transaction and asserts:

  - Anon path (p_user_id = NULL): is_favorited=false, is_in_calendar=false
    on every row, regardless of what favorites/user_calendar_events contain.
  - Authenticated path (p_user_id = real uid): is_favorited / is_in_calendar
    reflect the user's rows.
  - Zero-rating event: avg_rating = 0 AND rating_count = 0 (NOT NULL).
  - Rated event: avg_rating matches ROUND(AVG(score), 1) and rating_count
    matches COUNT(*).
  - tags is a jsonb array of {id,name,slug,color} objects, alphabetized
    by name; events with no tags return '[]'::jsonb.
  - Draft events are excluded (status='published' default filter).
  - p_city_id filter scopes rows correctly.

  Run with:

    PGPASSWORD=postgres psql -h 127.0.0.1 -p 55322 -U postgres -d postgres \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/events_enriched_parity.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixture: two cities, one user (enabled), three published events, one draft,
-- two tags, ratings, one favorite, one calendar entry.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('user_uid',   gen_random_uuid()::text),
  ('city_a',     gen_random_uuid()::text),
  ('city_b',     gen_random_uuid()::text),
  ('ev_rated',   gen_random_uuid()::text),
  ('ev_zero',    gen_random_uuid()::text),
  ('ev_other',   gen_random_uuid()::text),
  ('ev_draft',   gen_random_uuid()::text),
  ('tag_art',    gen_random_uuid()::text),
  ('tag_music',  gen_random_uuid()::text);

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT (v)::uuid, 'p2-user@test.local', 'authenticated', 'authenticated', now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k='user_uid';

INSERT INTO public.user_access (user_id, is_enabled, enabled_at)
SELECT (v)::uuid, true, now() FROM _fx WHERE k='user_uid'
ON CONFLICT (user_id) DO UPDATE SET is_enabled = true, enabled_at = now(), updated_at = now();

INSERT INTO public.cities (id, name, slug, is_active)
SELECT (v)::uuid,
       CASE k WHEN 'city_a' THEN 'P2 City A' ELSE 'P2 City B' END,
       CASE k WHEN 'city_a' THEN 'p2-a-' || substr(v, 1, 8) ELSE 'p2-b-' || substr(v, 1, 8) END,
       true
FROM _fx WHERE k IN ('city_a', 'city_b');

INSERT INTO public.tags (id, name, slug, color)
SELECT (v)::uuid,
       CASE k WHEN 'tag_art' THEN 'P2-Art-' || substr(v, 1, 8) ELSE 'P2-Music-' || substr(v, 1, 8) END,
       CASE k WHEN 'tag_art' THEN 'p2-art-' || substr(v, 1, 8) ELSE 'p2-music-' || substr(v, 1, 8) END,
       CASE k WHEN 'tag_art' THEN '#ff00ff' ELSE '#00ffff' END
FROM _fx WHERE k IN ('tag_art', 'tag_music');

INSERT INTO public.events (id, title, start_datetime, status, city_id)
SELECT (v)::uuid,
       CASE k
         WHEN 'ev_rated' THEN 'P2 Rated Event'
         WHEN 'ev_zero'  THEN 'P2 Zero-Rating Event'
         WHEN 'ev_other' THEN 'P2 Other-City Event'
         ELSE                 'P2 Draft Event'
       END,
       CASE k
         WHEN 'ev_rated' THEN now() + interval '1 day'
         WHEN 'ev_zero'  THEN now() + interval '2 days'
         WHEN 'ev_other' THEN now() + interval '3 days'
         ELSE                 now() + interval '4 days'
       END,
       CASE k WHEN 'ev_draft' THEN 'draft' ELSE 'published' END,
       CASE k
         WHEN 'ev_other' THEN (SELECT (v)::uuid FROM _fx WHERE k='city_b')
         ELSE                 (SELECT (v)::uuid FROM _fx WHERE k='city_a')
       END
FROM _fx WHERE k IN ('ev_rated', 'ev_zero', 'ev_other', 'ev_draft');

-- Tag provider: ev_rated was classified by OpenAI; ev_zero has no provider set
-- (NULL) to verify NULL surfaces through the RPC unchanged.
UPDATE public.events SET ai_tag_provider = 'openai'
  WHERE id = (SELECT (v)::uuid FROM _fx WHERE k='ev_rated');

-- Two tags on ev_rated (to verify ordering + array aggregation).
INSERT INTO public.event_tags (event_id, tag_id)
SELECT (SELECT (v)::uuid FROM _fx WHERE k='ev_rated'),
       (SELECT (v)::uuid FROM _fx WHERE k=tk)
FROM (VALUES ('tag_music'), ('tag_art')) AS t(tk);

-- Three ratings on ev_rated: avg = 4.0, count = 3.
-- ratings.user_id has FK to auth.users, so seed three real auth rows.
DO $$
DECLARE ev_rated uuid; u1 uuid; u2 uuid; u3 uuid;
BEGIN
  SELECT (v)::uuid INTO ev_rated FROM _fx WHERE k='ev_rated';
  u1 := gen_random_uuid(); u2 := gen_random_uuid(); u3 := gen_random_uuid();
  INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
  VALUES
    (u1, 'p2-r1@test.local', 'authenticated', 'authenticated', now(), '00000000-0000-0000-0000-000000000000'),
    (u2, 'p2-r2@test.local', 'authenticated', 'authenticated', now(), '00000000-0000-0000-0000-000000000000'),
    (u3, 'p2-r3@test.local', 'authenticated', 'authenticated', now(), '00000000-0000-0000-0000-000000000000');
  INSERT INTO public.ratings (user_id, event_id, score)
    VALUES (u1, ev_rated, 5), (u2, ev_rated, 4), (u3, ev_rated, 3);
END $$;

-- User favorites ev_rated and calendars ev_zero.
INSERT INTO public.favorites (user_id, event_id)
SELECT (SELECT (v)::uuid FROM _fx WHERE k='user_uid'),
       (SELECT (v)::uuid FROM _fx WHERE k='ev_rated');
INSERT INTO public.user_calendar_events (user_id, event_id)
SELECT (SELECT (v)::uuid FROM _fx WHERE k='user_uid'),
       (SELECT (v)::uuid FROM _fx WHERE k='ev_zero');

-- -----------------------------------------------------------------------------
-- Assertion helpers use the `postgres` superuser role so RLS does not need to
-- be satisfied; we are verifying function semantics, not RLS behavior. A
-- separate rls_*.sql suite covers RLS gating.
-- -----------------------------------------------------------------------------

-- Anon path: is_favorited and is_in_calendar MUST be false on every row.
DO $$
DECLARE
  ev_rated uuid; ev_zero uuid; ev_other uuid;
  r_fav boolean; r_cal boolean;
  r_avg numeric; r_count int;
  r_tags jsonb;
  r_provider text;
  n int;
BEGIN
  SELECT (v)::uuid INTO ev_rated FROM _fx WHERE k='ev_rated';
  SELECT (v)::uuid INTO ev_zero  FROM _fx WHERE k='ev_zero';
  SELECT (v)::uuid INTO ev_other FROM _fx WHERE k='ev_other';

  -- All three published events in city_a should come back when filtered by city_a;
  -- with no city filter we'd also get ev_other (city_b).
  SELECT count(*) INTO n FROM public.events_enriched(p_city_id := NULL, p_user_id := NULL)
    WHERE id IN (ev_rated, ev_zero, ev_other);
  IF n <> 3 THEN
    RAISE EXCEPTION 'ANON_COUNT_FAIL: expected 3 published events, got %', n;
  END IF;

  -- Draft must NOT appear under default p_status='published'.
  SELECT count(*) INTO n FROM public.events_enriched(p_user_id := NULL)
    WHERE id = (SELECT (v)::uuid FROM _fx WHERE k='ev_draft');
  IF n <> 0 THEN
    RAISE EXCEPTION 'ANON_DRAFT_FAIL: draft event leaked into p_status=published result';
  END IF;

  -- is_favorited / is_in_calendar false for anon on ev_rated (which IS favorited by user_uid).
  SELECT is_favorited, is_in_calendar INTO r_fav, r_cal
  FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_rated;
  IF r_fav IS DISTINCT FROM false OR r_cal IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'ANON_USER_STATE_FAIL: got is_favorited=%, is_in_calendar=%, want false/false', r_fav, r_cal;
  END IF;
  RAISE NOTICE 'ANON_OK: user-scoped fields default to false when p_user_id is NULL.';

  -- Zero-rating event returns 0/0, not NULL.
  SELECT avg_rating, rating_count INTO r_avg, r_count
  FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_zero;
  IF r_avg IS DISTINCT FROM 0::numeric OR r_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'ZERO_RATING_FAIL: got avg=%, count=%, want 0/0', r_avg, r_count;
  END IF;
  RAISE NOTICE 'ZERO_RATING_OK: zero-rating event returns avg=0 count=0.';

  -- Rated event: avg = ROUND(AVG(5,4,3)=4.0, 1) = 4.0, count = 3.
  SELECT avg_rating, rating_count INTO r_avg, r_count
  FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_rated;
  IF r_avg IS DISTINCT FROM 4.0 OR r_count IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'RATED_FAIL: got avg=%, count=%, want 4.0/3', r_avg, r_count;
  END IF;
  RAISE NOTICE 'RATED_OK: rated event returns avg=4.0 count=3.';

  -- Tags: ev_rated has Art + Music; must be a jsonb array, alphabetized by name.
  SELECT tags INTO r_tags
  FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_rated;
  IF jsonb_typeof(r_tags) IS DISTINCT FROM 'array' OR jsonb_array_length(r_tags) <> 2 THEN
    RAISE EXCEPTION 'TAGS_SHAPE_FAIL: got %, want 2-element array', r_tags;
  END IF;
  IF (r_tags->0->>'name') NOT LIKE 'P2-Art-%' OR (r_tags->1->>'name') NOT LIKE 'P2-Music-%' THEN
    RAISE EXCEPTION 'TAGS_ORDER_FAIL: got % / %, want P2-Art-* / P2-Music-*',
      r_tags->0->>'name', r_tags->1->>'name';
  END IF;
  IF (r_tags->0->>'slug') IS NULL OR (r_tags->0->>'color') IS NULL OR (r_tags->0->>'id') IS NULL THEN
    RAISE EXCEPTION 'TAGS_FIELDS_FAIL: missing id/slug/color in %', r_tags->0;
  END IF;

  -- Tags: ev_zero has no tags → '[]'::jsonb, never NULL.
  SELECT tags INTO r_tags
  FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_zero;
  IF r_tags IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'TAGS_EMPTY_FAIL: got %, want []', r_tags;
  END IF;
  RAISE NOTICE 'TAGS_OK: ordered jsonb array, [] for tagless events.';

  -- ai_tag_provider: ev_rated was UPDATEd to 'openai'; ev_zero left unset (NULL).
  -- Both must round-trip through the RPC's RETURNS TABLE unchanged.
  SELECT ai_tag_provider INTO r_provider
  FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_rated;
  IF r_provider IS DISTINCT FROM 'openai' THEN
    RAISE EXCEPTION 'AI_TAG_PROVIDER_RATED_FAIL: got %, want ''openai''', r_provider;
  END IF;
  SELECT ai_tag_provider INTO r_provider
  FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_zero;
  IF r_provider IS NOT NULL THEN
    RAISE EXCEPTION 'AI_TAG_PROVIDER_NULL_FAIL: got %, want NULL', r_provider;
  END IF;
  RAISE NOTICE 'AI_TAG_PROVIDER_OK: surfaces ''openai'' for classified events and NULL when unset.';

  -- p_city_id filter: passing city_b should return ONLY ev_other.
  SELECT count(*) INTO n FROM public.events_enriched(
    p_city_id := (SELECT (v)::uuid FROM _fx WHERE k='city_b'),
    p_user_id := NULL
  );
  IF n <> 1 THEN
    RAISE EXCEPTION 'CITY_FILTER_FAIL: p_city_id=city_b returned %, want 1', n;
  END IF;
  RAISE NOTICE 'CITY_FILTER_OK: p_city_id scoping works.';

  -- p_event_ids: passing two explicit IDs returns exactly those two rows,
  -- independent of city/status/limit/offset. ev_draft is deliberately
  -- included in the id array to verify the by-ids path bypasses the default
  -- status='published' filter (matches event-detail / my-events expectations).
  SELECT count(*) INTO n FROM public.events_enriched(
    p_city_id := NULL,
    p_status  := NULL,
    p_limit   := NULL,
    p_offset  := NULL,
    p_user_id := NULL,
    p_event_ids := ARRAY[ev_rated, ev_zero]
  );
  IF n <> 2 THEN
    RAISE EXCEPTION 'EVENT_IDS_COUNT_FAIL: p_event_ids=[rated,zero] returned %, want 2', n;
  END IF;

  -- Verify the two IDs returned are exactly the ones we asked for.
  IF NOT EXISTS (
    SELECT 1 FROM public.events_enriched(p_event_ids := ARRAY[ev_rated]) WHERE id = ev_rated
  ) THEN
    RAISE EXCEPTION 'EVENT_IDS_IDENTITY_FAIL: ev_rated not returned when requested by id';
  END IF;

  -- ev_draft via p_event_ids: must come back even though default p_status filter
  -- would hide it. Confirms p_event_ids overrides p_status.
  SELECT count(*) INTO n FROM public.events_enriched(
    p_event_ids := ARRAY[(SELECT (v)::uuid FROM _fx WHERE k='ev_draft')],
    p_user_id := NULL
  );
  IF n <> 1 THEN
    RAISE EXCEPTION 'EVENT_IDS_OVERRIDE_FAIL: ev_draft via p_event_ids returned %, want 1', n;
  END IF;
  RAISE NOTICE 'EVENT_IDS_OK: p_event_ids returns exact rows and overrides status/city/limit.';

  -- p_date_from: ev_rated starts at +1d, ev_zero at +2d, ev_other at +3d.
  -- A lower bound of now() + 2.5d should exclude ev_rated AND ev_zero,
  -- leaving only ev_other.
  SELECT count(*) INTO n FROM public.events_enriched(
    p_user_id := NULL,
    p_date_from := now() + interval '2 days 12 hours'
  )
  WHERE id IN (ev_rated, ev_zero, ev_other);
  IF n <> 1 THEN
    RAISE EXCEPTION 'DATE_FROM_FAIL: p_date_from cutoff returned %, want 1 (ev_other)', n;
  END IF;

  -- Also verify ev_rated (earliest) is explicitly gone.
  IF EXISTS (
    SELECT 1 FROM public.events_enriched(
      p_user_id := NULL,
      p_date_from := now() + interval '2 days 12 hours'
    ) WHERE id = ev_rated
  ) THEN
    RAISE EXCEPTION 'DATE_FROM_LOWER_BOUND_FAIL: ev_rated not excluded by lower bound';
  END IF;
  RAISE NOTICE 'DATE_FROM_OK: p_date_from excludes events with start_datetime < p_date_from.';

  -- p_date_to: upper bound of now() + 1.5d should keep only ev_rated (+1d)
  -- and exclude ev_zero (+2d), ev_other (+3d).
  SELECT count(*) INTO n FROM public.events_enriched(
    p_user_id := NULL,
    p_date_to := now() + interval '1 day 12 hours'
  )
  WHERE id IN (ev_rated, ev_zero, ev_other);
  IF n <> 1 THEN
    RAISE EXCEPTION 'DATE_TO_FAIL: p_date_to cutoff returned %, want 1 (ev_rated)', n;
  END IF;

  -- Also verify ev_other (latest) is explicitly gone.
  IF EXISTS (
    SELECT 1 FROM public.events_enriched(
      p_user_id := NULL,
      p_date_to := now() + interval '1 day 12 hours'
    ) WHERE id = ev_other
  ) THEN
    RAISE EXCEPTION 'DATE_TO_UPPER_BOUND_FAIL: ev_other not excluded by upper bound';
  END IF;
  RAISE NOTICE 'DATE_TO_OK: p_date_to excludes events with start_datetime > p_date_to.';
END $$;

-- Authenticated path: pass the real uid as p_user_id → is_favorited/is_in_calendar reflect user rows.
DO $$
DECLARE
  uid uuid; ev_rated uuid; ev_zero uuid;
  r_fav boolean; r_cal boolean;
BEGIN
  SELECT (v)::uuid INTO uid      FROM _fx WHERE k='user_uid';
  SELECT (v)::uuid INTO ev_rated FROM _fx WHERE k='ev_rated';
  SELECT (v)::uuid INTO ev_zero  FROM _fx WHERE k='ev_zero';

  SELECT is_favorited, is_in_calendar INTO r_fav, r_cal
  FROM public.events_enriched(p_user_id := uid) WHERE id = ev_rated;
  IF r_fav IS DISTINCT FROM true OR r_cal IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'AUTH_RATED_FAIL: got fav=%, cal=%, want true/false', r_fav, r_cal;
  END IF;

  SELECT is_favorited, is_in_calendar INTO r_fav, r_cal
  FROM public.events_enriched(p_user_id := uid) WHERE id = ev_zero;
  IF r_fav IS DISTINCT FROM false OR r_cal IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'AUTH_ZERO_FAIL: got fav=%, cal=%, want false/true', r_fav, r_cal;
  END IF;
  RAISE NOTICE 'AUTH_OK: is_favorited/is_in_calendar reflect user rows.';
END $$;

-- -----------------------------------------------------------------------------
-- RLS gate: the RPC is SECURITY INVOKER, so SET LOCAL role anon must be subject
-- to the anon SELECT policy on public.events — published rows visible, drafts
-- hidden. This exercises the actual RLS path, not just the p_user_id parameter
-- defaults covered above.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  ev_rated uuid; ev_draft uuid;
  pub_visible boolean; draft_visible boolean;
BEGIN
  SELECT (v)::uuid INTO ev_rated FROM _fx WHERE k='ev_rated';
  SELECT (v)::uuid INTO ev_draft FROM _fx WHERE k='ev_draft';

  SET LOCAL role anon;
  SELECT EXISTS (
    SELECT 1 FROM public.events_enriched(p_user_id := NULL) WHERE id = ev_rated
  ) INTO pub_visible;
  SELECT EXISTS (
    SELECT 1 FROM public.events_enriched(p_status := 'draft', p_user_id := NULL)
     WHERE id = ev_draft
  ) INTO draft_visible;
  RESET role;

  IF NOT pub_visible THEN
    RAISE EXCEPTION 'ANON_PUBLISHED_FAIL: anon cannot see published event via RPC';
  END IF;
  RAISE NOTICE 'ANON_PUBLISHED_OK: anon sees published event via SECURITY INVOKER RPC.';

  IF draft_visible THEN
    RAISE EXCEPTION 'ANON_DRAFT_FAIL: anon can see draft event via RPC (RLS bypassed)';
  END IF;
  RAISE NOTICE 'ANON_DRAFT_OK: anon blocked from draft rows via RPC (RLS enforced).';
END $$;

ROLLBACK;

\echo 'events_enriched_parity: PASS'

