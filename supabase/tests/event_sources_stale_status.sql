/*
  U1 test: event_sources.last_status accepts 'stale' (and still rejects junk).

  Covers:
    - 'stale' passes the check constraint after 20260816000000.
    - The four baseline statuses still pass.
    - An invalid status is still rejected (constraint remains enforced).

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/event_sources_stale_status.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

DO $$
DECLARE
  test_source_id uuid;
  status text;
  rejected boolean;
BEGIN
  INSERT INTO public.event_sources (name, url, source_type)
  VALUES ('U1 stale-status test source', 'https://example.test/u1', 'website')
  RETURNING id INTO test_source_id;

  -- Every valid status, including the newly allowed 'stale', must pass.
  FOREACH status IN ARRAY ARRAY['pending', 'success', 'error', 'partial', 'stale']
  LOOP
    BEGIN
      UPDATE public.event_sources
      SET last_status = status
      WHERE id = test_source_id;
    EXCEPTION WHEN check_violation THEN
      RAISE EXCEPTION 'STALE_STATUS_FAIL: last_status = % violated event_sources_last_status_check', status;
    END;
  END LOOP;

  -- An unknown status must still be rejected.
  rejected := false;
  BEGIN
    UPDATE public.event_sources
    SET last_status = 'bogus'
    WHERE id = test_source_id;
  EXCEPTION WHEN check_violation THEN
    rejected := true;
  END;

  IF NOT rejected THEN
    RAISE EXCEPTION 'STALE_STATUS_FAIL: last_status = bogus was accepted — constraint missing or too loose';
  END IF;

  RAISE NOTICE 'event_sources_stale_status: PASS';
END $$;

ROLLBACK;
