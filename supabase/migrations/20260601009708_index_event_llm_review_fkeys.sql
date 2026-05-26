-- Supabase performance advisors require plain covering indexes for foreign-key
-- columns. The existing partial indexes on nullable source/queue columns are
-- good for app reads, but the FK advisor does not count them as covering
-- indexes for referential actions.

DROP INDEX IF EXISTS public.event_llm_review_queue_source_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_queue_source_run_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_queue_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_source_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_source_run_id_idx;

CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_id_idx
  ON public.event_llm_review_queue USING btree (source_id);

CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_run_id_idx
  ON public.event_llm_review_queue USING btree (source_run_id);

CREATE INDEX IF NOT EXISTS event_llm_review_traces_queue_id_idx
  ON public.event_llm_review_traces USING btree (queue_id);

CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_id_idx
  ON public.event_llm_review_traces USING btree (source_id);

CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_run_id_idx
  ON public.event_llm_review_traces USING btree (source_run_id);
