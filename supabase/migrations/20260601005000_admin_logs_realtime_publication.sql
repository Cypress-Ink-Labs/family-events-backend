-- Realtime subscriptions now power admin log tails. The events tables in
-- this UI path are not added by default, so this migration ensures
-- source runs and both durable queues are published.
DO $$
BEGIN
  IF to_regclass('public.source_runs') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'source_runs'
    ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.source_runs;
  END IF;

  IF to_regclass('public.source_scrape_queue') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'source_scrape_queue'
    ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.source_scrape_queue;
  END IF;

  IF to_regclass('public.event_tag_queue') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'event_tag_queue'
    ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_tag_queue;
  END IF;
END $$;
