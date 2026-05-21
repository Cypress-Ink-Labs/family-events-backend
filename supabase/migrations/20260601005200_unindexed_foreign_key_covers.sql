-- Add covering indexes for foreign keys flagged by advisor lint 0001
-- (unindexed_foreign_keys). Existing partial / composite indexes on these
-- columns do not satisfy the planner's FK lookup heuristic.

CREATE INDEX IF NOT EXISTS events_admin_last_edited_by_idx
  ON public.events (admin_last_edited_by)
  WHERE admin_last_edited_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS source_extraction_traces_source_id_idx
  ON public.source_extraction_traces (source_id)
  WHERE source_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS source_extraction_traces_source_queue_id_idx
  ON public.source_extraction_traces (source_queue_id)
  WHERE source_queue_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS source_scrape_queue_source_run_id_idx
  ON public.source_scrape_queue (source_run_id)
  WHERE source_run_id IS NOT NULL;
