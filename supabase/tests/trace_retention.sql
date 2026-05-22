/*
  # Trace retention

  Verifies that private.run_daily_maintenance() prunes rows older than 90 days
  from public.event_ai_traces and public.source_extraction_traces while leaving
  recent rows intact.

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/trace_retention.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- Seed a minimal event to satisfy event_ai_traces.event_id FK
INSERT INTO public.events (id, title, start_datetime, status)
VALUES (
  '00000000-aaaa-bbbb-cccc-000000000001'::uuid,
  'Trace Retention Test Event',
  now() + interval '1 day',
  'draft'
);

-- =============================================
-- 1. Seed event_ai_traces: 2 recent, 2 old
-- =============================================
INSERT INTO public.event_ai_traces
  (id, event_id, trigger_type, status, input_title, created_at)
VALUES
  (gen_random_uuid(), '00000000-aaaa-bbbb-cccc-000000000001'::uuid, 'import', 'success', 'recent-1', now()),
  (gen_random_uuid(), '00000000-aaaa-bbbb-cccc-000000000001'::uuid, 'import', 'success', 'recent-2', now()),
  (gen_random_uuid(), '00000000-aaaa-bbbb-cccc-000000000001'::uuid, 'import', 'success', 'old-1',    now() - interval '100 days'),
  (gen_random_uuid(), '00000000-aaaa-bbbb-cccc-000000000001'::uuid, 'import', 'success', 'old-2',    now() - interval '100 days');

-- =============================================
-- 2. Seed source_extraction_traces: 2 recent, 2 old
-- =============================================
INSERT INTO public.source_extraction_traces
  (extraction_mode, extractor, status, created_at)
VALUES
  ('deterministic', 'deterministic', 'success', now()),
  ('deterministic', 'deterministic', 'success', now()),
  ('deterministic', 'deterministic', 'success', now() - interval '100 days'),
  ('deterministic', 'deterministic', 'success', now() - interval '100 days');

-- =============================================
-- 3. Run maintenance
-- =============================================
DO $$
DECLARE
  result jsonb;
BEGIN
  SELECT private.run_daily_maintenance() INTO result;
  RAISE NOTICE 'maintenance result: %', result;
END $$;

-- =============================================
-- 4. Assert: old event_ai_traces deleted
-- =============================================
DO $$
DECLARE
  old_count   int;
  recent_count int;
BEGIN
  SELECT count(*) INTO old_count
  FROM public.event_ai_traces
  WHERE input_title IN ('old-1', 'old-2');

  IF old_count <> 0 THEN
    RAISE EXCEPTION 'AI_TRACES_OLD_FAIL: expected 0 old rows, got %', old_count;
  END IF;
  RAISE NOTICE 'AI_TRACES_OLD_OK';

  SELECT count(*) INTO recent_count
  FROM public.event_ai_traces
  WHERE input_title IN ('recent-1', 'recent-2');

  IF recent_count <> 2 THEN
    RAISE EXCEPTION 'AI_TRACES_RECENT_FAIL: expected 2 recent rows, got %', recent_count;
  END IF;
  RAISE NOTICE 'AI_TRACES_RECENT_OK';
END $$;

-- =============================================
-- 5. Assert: old source_extraction_traces deleted
-- =============================================
DO $$
DECLARE
  old_count    int;
  recent_count int;
  cutoff       timestamptz;
BEGIN
  cutoff := now() - interval '90 days';

  SELECT count(*) INTO old_count
  FROM public.source_extraction_traces
  WHERE created_at < cutoff;

  IF old_count <> 0 THEN
    RAISE EXCEPTION 'EXTRACTION_TRACES_OLD_FAIL: expected 0 old rows, got %', old_count;
  END IF;
  RAISE NOTICE 'EXTRACTION_TRACES_OLD_OK';

  SELECT count(*) INTO recent_count
  FROM public.source_extraction_traces
  WHERE created_at >= cutoff;

  IF recent_count <> 2 THEN
    RAISE EXCEPTION 'EXTRACTION_TRACES_RECENT_FAIL: expected 2 recent rows, got %', recent_count;
  END IF;
  RAISE NOTICE 'EXTRACTION_TRACES_RECENT_OK';
END $$;

ROLLBACK;

\echo 'trace_retention: PASS'
