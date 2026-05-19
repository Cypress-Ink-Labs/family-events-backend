/*
  # Saturday Plan RLS integration

  Verifies the security boundary for public event previews:
  - anon can read public.public_events
  - anon can read published raw public.events rows, matching the
    security-invoker public_events policy
  - anon cannot read draft raw public.events rows
  - anon-reachable child tables (event_tags, ratings, comments) honor
    the public_events boundary: visible for published events, blocked
    for draft events
  - plan_events_for_user RPC refuses calls where p_user_id != auth.uid()

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/rls_public_events_view.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixture: published event + draft event, both with tag/rating/comment rows.
-- Also a tag, a fake user, and a published-approved comment + an approved-but-
-- draft-event comment. Each child row is replicated on both events so we can
-- assert "anon sees published, not draft" symmetrically.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _fx_sat_plan (k text PRIMARY KEY, v text);
INSERT INTO _fx_sat_plan VALUES
  ('published_event', gen_random_uuid()::text),
  ('draft_event',     gen_random_uuid()::text),
  ('city_id',         gen_random_uuid()::text),
  ('tag_id',          gen_random_uuid()::text),
  ('user_id',         gen_random_uuid()::text);

INSERT INTO public.cities (id, name, slug, is_active)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'city_id'),
  'Saturday Plan Test City',
  'sat-plan-test-' || substr((SELECT v FROM _fx_sat_plan WHERE k = 'city_id'), 1, 8),
  true
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.tags (id, name, slug)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'tag_id'),
  'Sat Plan Test Tag ' || substr((SELECT v FROM _fx_sat_plan WHERE k = 'tag_id'), 1, 8),
  'sat-plan-test-' || substr((SELECT v FROM _fx_sat_plan WHERE k = 'tag_id'), 1, 8)
ON CONFLICT (id) DO NOTHING;

-- Need a real auth.users row so user_profiles FK + handle_new_user trigger are happy.
INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'user_id'),
  'sat-plan-rls-test@test.local',
  'authenticated',
  'authenticated',
  now(),
  '00000000-0000-0000-0000-000000000000'
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'user_id'),
  'sat-plan-rls-test@test.local',
  'Sat Plan Test User',
  'user'
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, updated_at = now();

INSERT INTO public.events (
  id, title, description, start_datetime, end_datetime,
  venue_name, address, city_id, images, price, is_free, source_url, status
)
VALUES
  (
    (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event'),
    'Saturday Plan Published Event',
    'Published event used by public view RLS test',
    now() + interval '1 day',
    now() + interval '1 day' + interval '1 hour',
    'Family Library', '123 Test Ave',
    (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'city_id'),
    '[]'::jsonb, 0, true, 'https://example.com/sat-plan-pub', 'published'
  ),
  (
    (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event'),
    'Saturday Plan Draft Event',
    'Draft event used to assert anon cannot reach child rows',
    now() + interval '2 day',
    now() + interval '2 day' + interval '1 hour',
    'Family Library', '123 Test Ave',
    (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'city_id'),
    '[]'::jsonb, 0, true, 'https://example.com/sat-plan-draft', 'draft'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.event_tags (event_id, tag_id)
SELECT (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event'),
       (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'tag_id')
ON CONFLICT DO NOTHING;
INSERT INTO public.event_tags (event_id, tag_id)
SELECT (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event'),
       (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'tag_id')
ON CONFLICT DO NOTHING;

INSERT INTO public.ratings (user_id, event_id, score)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'user_id'),
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event'),
  4
ON CONFLICT (user_id, event_id) DO NOTHING;
INSERT INTO public.ratings (user_id, event_id, score)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'user_id'),
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event'),
  5
ON CONFLICT (user_id, event_id) DO NOTHING;

INSERT INTO public.comments (user_id, event_id, body, is_approved)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'user_id'),
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event'),
  'approved comment on published event',
  true;
INSERT INTO public.comments (user_id, event_id, body, is_approved)
SELECT
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'user_id'),
  (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event'),
  'approved comment on DRAFT event — anon must not see this',
  true;

-- -----------------------------------------------------------------------------
-- Anon: published events visible via view and raw table; draft rows blocked.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  pub_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event');
  draft_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event');
  view_visible boolean := false;
  raw_pub_visible boolean := false;
  raw_draft_visible boolean := false;
BEGIN
  SET LOCAL role anon;
  SELECT EXISTS (SELECT 1 FROM public.public_events WHERE id = pub_uuid)
    INTO view_visible;
  SELECT EXISTS (SELECT 1 FROM public.events WHERE id = pub_uuid)
    INTO raw_pub_visible;
  SELECT EXISTS (SELECT 1 FROM public.events WHERE id = draft_uuid)
    INTO raw_draft_visible;
  RESET role;

  IF NOT view_visible THEN
    RAISE EXCEPTION 'PUBLIC_EVENTS_VIEW_FAIL: anon could not read public.public_events';
  END IF;
  IF NOT raw_pub_visible THEN
    RAISE EXCEPTION 'PUBLIC_EVENTS_RAW_PUB_FAIL: anon could not read published raw public.events';
  END IF;
  IF raw_draft_visible THEN
    RAISE EXCEPTION 'PUBLIC_EVENTS_BOUNDARY_FAIL: anon can read draft raw public.events';
  END IF;
  RAISE NOTICE 'PUBLIC_EVENTS_BOUNDARY_OK: anon reads published view/raw rows; draft raw rows blocked.';
END $$;

-- -----------------------------------------------------------------------------
-- Anon: event_tags visible for published, blocked for draft.
-- Catches regressions where child-table policies expose draft event children.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  pub_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event');
  draft_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event');
  pub_tag_visible boolean;
  draft_tag_visible boolean;
BEGIN
  SET LOCAL role anon;
  SELECT EXISTS (SELECT 1 FROM public.event_tags WHERE event_id = pub_uuid)
    INTO pub_tag_visible;
  SELECT EXISTS (SELECT 1 FROM public.event_tags WHERE event_id = draft_uuid)
    INTO draft_tag_visible;
  RESET role;

  IF NOT pub_tag_visible THEN
    RAISE EXCEPTION 'EVENT_TAGS_PUB_FAIL: anon cannot read tags for published event';
  END IF;
  IF draft_tag_visible THEN
    RAISE EXCEPTION 'EVENT_TAGS_DRAFT_FAIL: anon can read tags for draft event';
  END IF;
  RAISE NOTICE 'EVENT_TAGS_OK: anon sees published tags, draft tags blocked.';
END $$;

-- -----------------------------------------------------------------------------
-- Anon: ratings visible for published, blocked for draft.
-- Also exercises event_rating_stats view (security_invoker, anon-grant).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  pub_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event');
  draft_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event');
  pub_rating_visible boolean;
  draft_rating_visible boolean;
  pub_stats_count int;
BEGIN
  SET LOCAL role anon;
  SELECT EXISTS (SELECT 1 FROM public.ratings WHERE event_id = pub_uuid)
    INTO pub_rating_visible;
  SELECT EXISTS (SELECT 1 FROM public.ratings WHERE event_id = draft_uuid)
    INTO draft_rating_visible;
  SELECT COALESCE(rating_count, 0)
  FROM public.event_rating_stats
  WHERE event_id = pub_uuid
  INTO pub_stats_count;
  RESET role;

  IF NOT pub_rating_visible THEN
    RAISE EXCEPTION 'RATINGS_PUB_FAIL: anon cannot read ratings for published event';
  END IF;
  IF draft_rating_visible THEN
    RAISE EXCEPTION 'RATINGS_DRAFT_FAIL: anon can read ratings for draft event';
  END IF;
  IF COALESCE(pub_stats_count, 0) < 1 THEN
    RAISE EXCEPTION 'RATING_STATS_FAIL: event_rating_stats returns zero rows for anon on published event';
  END IF;
  RAISE NOTICE 'RATINGS_OK: anon sees published ratings + stats, draft ratings blocked.';
END $$;

-- -----------------------------------------------------------------------------
-- Anon: approved comments visible for published, blocked for draft.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  pub_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'published_event');
  draft_uuid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'draft_event');
  pub_comment_visible boolean;
  draft_comment_visible boolean;
BEGIN
  SET LOCAL role anon;
  SELECT EXISTS (SELECT 1 FROM public.comments WHERE event_id = pub_uuid)
    INTO pub_comment_visible;
  SELECT EXISTS (SELECT 1 FROM public.comments WHERE event_id = draft_uuid)
    INTO draft_comment_visible;
  RESET role;

  IF NOT pub_comment_visible THEN
    RAISE EXCEPTION 'COMMENTS_PUB_FAIL: anon cannot read approved comment on published event';
  END IF;
  IF draft_comment_visible THEN
    RAISE EXCEPTION 'COMMENTS_DRAFT_FAIL: anon can read approved comment on draft event';
  END IF;
  RAISE NOTICE 'COMMENTS_OK: anon sees published comments, draft comments blocked.';
END $$;

-- -----------------------------------------------------------------------------
-- plan_events_for_user: caller can only request their own scoring.
-- Authenticated user passing a different UUID gets 42501.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  caller_uid uuid := (SELECT v::uuid FROM _fx_sat_plan WHERE k = 'user_id');
  victim_uid uuid := gen_random_uuid();
  err_code text;
  raised boolean := false;
BEGIN
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', caller_uid::text, true);

  BEGIN
    PERFORM public.plan_events_for_user(p_user_id => victim_uid);
  EXCEPTION
    WHEN insufficient_privilege THEN
      raised := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err_code = RETURNED_SQLSTATE;
      IF err_code = '42501' THEN
        raised := true;
      ELSE
        RESET role;
        RAISE EXCEPTION 'PLAN_RPC_FAIL: unexpected SQLSTATE % (%)', err_code, SQLERRM;
      END IF;
  END;

  RESET role;
  IF NOT raised THEN
    RAISE EXCEPTION 'PLAN_RPC_FAIL: plan_events_for_user did not block cross-user p_user_id';
  END IF;
  RAISE NOTICE 'PLAN_RPC_OK: cross-user p_user_id blocked with 42501.';
END $$;

ROLLBACK;

\echo 'rls_public_events_view: PASS'
