/*
  U2 test: private.redrive_constraint_bug_dead_letters behavior.

  Covers:
    - A dead row with the constraint-bug signature becomes pending with
      attempt_count reset to 0.
    - A dead row with an unrelated failure cause is not modified.
    - A source that already has an active queue row is not redriven into a
      second active row (at most one active row per source afterward).
    - Dry-run returns the candidate set without writing.

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/redrive_constraint_bug_dead_letters.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

DO $$
DECLARE
  src_bug uuid;
  src_other uuid;
  src_active uuid;
  q_bug bigint;
  q_other bigint;
  q_active_dead bigint;
  dry_count integer;
  bug_status text;
  bug_attempts integer;
  other_status text;
  active_dead_status text;
  active_rows integer;
BEGIN
  INSERT INTO public.event_sources (name, url, source_type)
  VALUES ('U2 bug-signature source', 'https://example.test/u2-bug', 'website')
  RETURNING id INTO src_bug;
  INSERT INTO public.event_sources (name, url, source_type)
  VALUES ('U2 other-failure source', 'https://example.test/u2-other', 'website')
  RETURNING id INTO src_other;
  INSERT INTO public.event_sources (name, url, source_type)
  VALUES ('U2 already-active source', 'https://example.test/u2-active', 'website')
  RETURNING id INTO src_active;

  -- Dead with the constraint-bug signature: should redrive.
  INSERT INTO public.source_scrape_queue (source_id, trigger_type, status, attempt_count, finished_at, last_error)
  VALUES (src_bug, 'scheduled', 'dead', 4, now(),
          'update failed: new row for relation "event_sources" violates check constraint "event_sources_last_status_check" (23514)')
  RETURNING id INTO q_bug;

  -- Dead with an unrelated cause: must be untouched.
  INSERT INTO public.source_scrape_queue (source_id, trigger_type, status, attempt_count, finished_at, last_error)
  VALUES (src_other, 'scheduled', 'dead', 4, now(), 'fetch timeout after 30000ms')
  RETURNING id INTO q_other;

  -- Dead with the signature BUT the source already has an active pending row:
  -- must not create a second active row.
  INSERT INTO public.source_scrape_queue (source_id, trigger_type, status, attempt_count, finished_at, last_error)
  VALUES (src_active, 'scheduled', 'dead', 4, now(),
          'violates check constraint "event_sources_last_status_check"')
  RETURNING id INTO q_active_dead;
  INSERT INTO public.source_scrape_queue (source_id, trigger_type, status)
  VALUES (src_active, 'scheduled', 'pending');

  -- Dry run: exactly one candidate (src_bug), and nothing written.
  SELECT count(*) INTO dry_count
  FROM private.redrive_constraint_bug_dead_letters(true);
  IF dry_count <> 1 THEN
    RAISE EXCEPTION 'REDRIVE_FAIL: dry run expected 1 candidate, got %', dry_count;
  END IF;

  SELECT status::text INTO bug_status FROM public.source_scrape_queue WHERE id = q_bug;
  IF bug_status <> 'dead' THEN
    RAISE EXCEPTION 'REDRIVE_FAIL: dry run mutated queue row % (status %)', q_bug, bug_status;
  END IF;

  -- Apply.
  PERFORM private.redrive_constraint_bug_dead_letters(false);

  SELECT status::text, attempt_count INTO bug_status, bug_attempts
  FROM public.source_scrape_queue WHERE id = q_bug;
  IF bug_status <> 'pending' OR bug_attempts <> 0 THEN
    RAISE EXCEPTION 'REDRIVE_FAIL: bug-signature row expected pending/0, got %/%', bug_status, bug_attempts;
  END IF;

  SELECT status::text INTO other_status FROM public.source_scrape_queue WHERE id = q_other;
  IF other_status <> 'dead' THEN
    RAISE EXCEPTION 'REDRIVE_FAIL: unrelated dead row was modified (status %)', other_status;
  END IF;

  SELECT status::text INTO active_dead_status FROM public.source_scrape_queue WHERE id = q_active_dead;
  IF active_dead_status <> 'dead' THEN
    RAISE EXCEPTION 'REDRIVE_FAIL: source with active row was redriven (status %)', active_dead_status;
  END IF;

  SELECT count(*) INTO active_rows
  FROM public.source_scrape_queue
  WHERE source_id = src_active
    AND status IN ('pending', 'processing', 'retrying');
  IF active_rows <> 1 THEN
    RAISE EXCEPTION 'REDRIVE_FAIL: expected exactly 1 active row for already-active source, got %', active_rows;
  END IF;

  RAISE NOTICE 'redrive_constraint_bug_dead_letters: PASS';
END $$;

ROLLBACK;
