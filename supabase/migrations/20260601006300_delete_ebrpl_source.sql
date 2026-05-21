/*
  # Delete EBRPL Parish Library event source

  The libcal install (https://ebrpl.libcal.com/rss.php) is effectively empty
  ("No calendar id provided" + only a "Test Calendar" in the dashboard), and
  the real EBRPL events live in a LocalHop widget gated behind Parse SDK
  auth. Pursuing that integration is a separate project, not a bugfix.

  - events: 0 rows reference this source today, but FK is SET NULL so the
    column would orphan to NULL even if any existed later.
  - source_runs: 31 rows, FK ON DELETE CASCADE — they go away with the
    source.
  - source_scrape_queue + source_extraction_traces: FK SET NULL, so the
    queue row and trace would linger with source_id = NULL. Delete those
    rows explicitly first so we don't leak orphans.
*/

BEGIN;

DELETE FROM public.source_extraction_traces
WHERE source_id = '48a68ac1-8642-44ba-bb12-050d510d798d';

DELETE FROM public.source_scrape_queue
WHERE source_id = '48a68ac1-8642-44ba-bb12-050d510d798d';

DELETE FROM public.event_sources
WHERE id = '48a68ac1-8642-44ba-bb12-050d510d798d';

COMMIT;
