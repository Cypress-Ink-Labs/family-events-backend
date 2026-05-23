\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fixture_users (key text PRIMARY KEY, id uuid);
INSERT INTO _fixture_users (key, id)
VALUES ('admin_uid', gen_random_uuid());

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT
  id,
  'llm-review-admin@test.local',
  'authenticated',
  'authenticated',
  now(),
  '00000000-0000-0000-0000-000000000000'
FROM _fixture_users
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  aud = EXCLUDED.aud,
  role = EXCLUDED.role,
  updated_at = now();

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT id, 'llm-review-admin@test.local', 'LLM Review Admin', 'admin'
FROM _fixture_users
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  display_name = EXCLUDED.display_name,
  role = EXCLUDED.role,
  updated_at = now();

INSERT INTO public.user_access (user_id, is_enabled, enabled_at)
SELECT id, true, now()
FROM _fixture_users
ON CONFLICT (user_id) DO UPDATE SET
  is_enabled = true,
  enabled_at = COALESCE(public.user_access.enabled_at, now()),
  updated_at = now();

DO $$
DECLARE
  default_source_id uuid;
  manual_source_id uuid;
  auto_source_id uuid;
  llm_source_id uuid;
  run_manual uuid;
  run_auto uuid;
  run_llm uuid;
  payload_manual jsonb;
  payload_auto jsonb;
  payload_llm jsonb;
  manual_event_id uuid;
  auto_event_id uuid;
  llm_event_id uuid;
  active_llm_rows integer;
  admin_uid uuid;
  filtered_count bigint;
BEGIN
  INSERT INTO public.event_sources (
    name,
    url,
    source_type,
    is_active,
    auto_approve,
    scrape_interval_hours,
    last_status,
    error_count
  )
  VALUES (
    'Default Processing Mode Source',
    'https://example.com/default-processing-mode',
    'rss',
    true,
    false,
    24,
    'pending',
    0
  )
  RETURNING id INTO default_source_id;

  IF (
    SELECT processing_mode
    FROM public.event_sources
    WHERE id = default_source_id
  ) IS DISTINCT FROM 'manual_review'::public.event_processing_mode THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: default processing_mode should be manual_review';
  END IF;

  INSERT INTO public.event_sources (
    name,
    url,
    source_type,
    is_active,
    auto_approve,
    processing_mode,
    scrape_interval_hours,
    last_status,
    error_count
  )
  VALUES (
    'Manual Review Source',
    'https://example.com/manual-review-source',
    'rss',
    true,
    false,
    'manual_review'::public.event_processing_mode,
    24,
    'pending',
    0
  )
  RETURNING id INTO manual_source_id;

  INSERT INTO public.event_sources (
    name,
    url,
    source_type,
    is_active,
    auto_approve,
    processing_mode,
    scrape_interval_hours,
    last_status,
    error_count
  )
  VALUES (
    'Auto Approve Source',
    'https://example.com/auto-approve-source',
    'rss',
    true,
    true,
    'auto_approve'::public.event_processing_mode,
    24,
    'pending',
    0
  )
  RETURNING id INTO auto_source_id;

  INSERT INTO public.event_sources (
    name,
    url,
    source_type,
    is_active,
    auto_approve,
    processing_mode,
    scrape_interval_hours,
    last_status,
    error_count
  )
  VALUES (
    'LLM Review Source',
    'https://example.com/llm-review-source',
    'rss',
    true,
    false,
    'llm_review'::public.event_processing_mode,
    24,
    'pending',
    0
  )
  RETURNING id INTO llm_source_id;

  INSERT INTO public.source_runs (source_id, status)
  VALUES (manual_source_id, 'running')
  RETURNING id INTO run_manual;

  INSERT INTO public.source_runs (source_id, status)
  VALUES (auto_source_id, 'running')
  RETURNING id INTO run_auto;

  INSERT INTO public.source_runs (source_id, status)
  VALUES (llm_source_id, 'running')
  RETURNING id INTO run_llm;

  payload_manual := jsonb_build_array(jsonb_build_object(
    'title', 'Manual Imported Event',
    'description', 'manual event description',
    'start_datetime', '2026-06-10T12:00:00Z',
    'end_datetime', null,
    'timezone', 'America/Chicago',
    'venue_name', 'Manual Venue',
    'address', '123 Manual St',
    'city_id', null,
    'source_url', 'https://example.com/manual-review-source/events/1',
    'source_name', 'Manual Review Source',
    'images', '[]'::jsonb,
    'price', null,
    'is_free', true,
    'is_outdoor', null,
    'latitude', null,
    'longitude', null
  ));

  payload_auto := jsonb_build_array(jsonb_build_object(
    'title', 'Auto Imported Event',
    'description', 'auto event description',
    'start_datetime', '2026-06-11T12:00:00Z',
    'end_datetime', null,
    'timezone', 'America/Chicago',
    'venue_name', 'Auto Venue',
    'address', '123 Auto St',
    'city_id', null,
    'source_url', 'https://example.com/auto-approve-source/events/1',
    'source_name', 'Auto Approve Source',
    'images', '[]'::jsonb,
    'price', null,
    'is_free', true,
    'is_outdoor', null,
    'latitude', null,
    'longitude', null
  ));

  payload_llm := jsonb_build_array(jsonb_build_object(
    'title', 'LLM Imported Event',
    'description', 'llm event description',
    'start_datetime', '2026-06-12T12:00:00Z',
    'end_datetime', null,
    'timezone', 'America/Chicago',
    'venue_name', 'LLM Venue',
    'address', '123 LLM St',
    'city_id', null,
    'source_url', 'https://example.com/llm-review-source/events/1',
    'source_name', 'LLM Review Source',
    'images', '[]'::jsonb,
    'price', null,
    'is_free', true,
    'is_outdoor', null,
    'latitude', null,
    'longitude', null
  ));

  PERFORM public.bulk_import_scrape_events(run_manual, manual_source_id, payload_manual);
  PERFORM public.bulk_import_scrape_events(run_auto, auto_source_id, payload_auto);
  PERFORM public.bulk_import_scrape_events(run_llm, llm_source_id, payload_llm);

  SELECT id INTO manual_event_id FROM public.events WHERE source_id = manual_source_id LIMIT 1;
  SELECT id INTO auto_event_id FROM public.events WHERE source_id = auto_source_id LIMIT 1;
  SELECT id INTO llm_event_id FROM public.events WHERE source_id = llm_source_id LIMIT 1;

  IF (
    SELECT status FROM public.events WHERE id = manual_event_id
  ) IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: manual_review import should create draft events';
  END IF;

  IF (
    SELECT llm_review_status FROM public.events WHERE id = manual_event_id
  ) IS DISTINCT FROM 'not_required'::public.llm_event_review_status THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: manual_review import should set llm_review_status=not_required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.event_llm_review_queue WHERE event_id = manual_event_id
  ) THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: manual_review import should not enqueue llm queue rows';
  END IF;

  IF (
    SELECT status FROM public.events WHERE id = auto_event_id
  ) IS DISTINCT FROM 'published' THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: auto_approve import should create published events';
  END IF;

  IF (
    SELECT llm_review_status FROM public.events WHERE id = auto_event_id
  ) IS DISTINCT FROM 'not_required'::public.llm_event_review_status THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: auto_approve import should set llm_review_status=not_required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.event_llm_review_queue WHERE event_id = auto_event_id
  ) THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: auto_approve import should not enqueue llm queue rows';
  END IF;

  IF (
    SELECT status FROM public.events WHERE id = llm_event_id
  ) IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: llm_review import should create draft events';
  END IF;

  IF (
    SELECT llm_review_status FROM public.events WHERE id = llm_event_id
  ) IS DISTINCT FROM 'pending'::public.llm_event_review_status THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: llm_review import should set llm_review_status=pending';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.event_tag_queue WHERE event_id = llm_event_id AND status IN ('pending', 'processing')
  ) THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: llm_review import should not enqueue tag queue rows';
  END IF;

  SELECT COUNT(*)::integer INTO active_llm_rows
  FROM public.event_llm_review_queue
  WHERE event_id = llm_event_id
    AND status IN ('pending', 'processing', 'retrying');

  IF active_llm_rows IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: llm_review import should create exactly one active queue row, got %', active_llm_rows;
  END IF;

  PERFORM public.bulk_import_scrape_events(run_llm, llm_source_id, payload_llm);

  SELECT COUNT(*)::integer INTO active_llm_rows
  FROM public.event_llm_review_queue
  WHERE event_id = llm_event_id
    AND status IN ('pending', 'processing', 'retrying');

  IF active_llm_rows IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: llm_review re-import should not duplicate active queue rows, got %', active_llm_rows;
  END IF;

  SELECT id INTO admin_uid FROM _fixture_users WHERE key = 'admin_uid';
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', admin_uid::text, true);

  PERFORM public.admin_bulk_set_auto_approve(true);
  IF (
    SELECT processing_mode FROM public.event_sources WHERE id = manual_source_id
  ) IS DISTINCT FROM 'auto_approve'::public.event_processing_mode THEN
    RESET ROLE;
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: admin_bulk_set_auto_approve(true) should sync processing_mode=auto_approve';
  END IF;

  PERFORM public.admin_bulk_set_auto_approve(false);
  IF (
    SELECT processing_mode FROM public.event_sources WHERE id = manual_source_id
  ) IS DISTINCT FROM 'manual_review'::public.event_processing_mode THEN
    RESET ROLE;
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: admin_bulk_set_auto_approve(false) should sync processing_mode=manual_review';
  END IF;

  PERFORM public.admin_bulk_set_processing_mode('llm_review'::public.event_processing_mode);
  IF (
    SELECT processing_mode FROM public.event_sources WHERE id = manual_source_id
  ) IS DISTINCT FROM 'llm_review'::public.event_processing_mode THEN
    RESET ROLE;
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: admin_bulk_set_processing_mode(llm_review) should update sources';
  END IF;

  SELECT COUNT(*) INTO filtered_count
  FROM public.admin_events_enriched(
    p_llm_review_status => 'pending'::public.llm_event_review_status,
    p_limit => 500
  )
  WHERE id = llm_event_id;

  RESET ROLE;

  IF filtered_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'LLM_REVIEW_TEST_FAIL: admin_events_enriched llm status filter should include llm pending events';
  END IF;

  RAISE NOTICE 'LLM_REVIEW_PROCESSING_OK';
END $$;

ROLLBACK;

\echo 'llm_event_review_processing: PASS'
