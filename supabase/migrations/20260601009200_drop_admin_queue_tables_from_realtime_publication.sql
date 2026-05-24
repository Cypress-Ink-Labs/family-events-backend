-- Drop high-churn admin queue tables from supabase_realtime publication.
-- event_tag_queue alone produced ~28k WAL rows over the prior sampling
-- window with zero realtime subscribers, dominating realtime.list_changes
-- cost (63.9% of total DB time). Admin UI now polls these tables every
-- 10s instead of subscribing via postgres_changes.
ALTER PUBLICATION supabase_realtime DROP TABLE public.event_tag_queue;
ALTER PUBLICATION supabase_realtime DROP TABLE public.source_scrape_queue;
ALTER PUBLICATION supabase_realtime DROP TABLE public.source_runs;
