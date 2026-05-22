-- no-transaction
-- pg_stat_statements index_advisor: admin tag queue query (1278 calls, ~23 ms mean)
-- filters by status, orders by finished_at DESC — seq scan costs 1365→275 with this index.

CREATE INDEX CONCURRENTLY IF NOT EXISTS event_tag_queue_finished_at_idx
  ON public.event_tag_queue (finished_at);
