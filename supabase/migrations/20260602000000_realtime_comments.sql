-- REPLICA IDENTITY FULL is required for DELETE events to include all columns
-- in the Realtime payload. Without it, DELETE payloads only carry the primary
-- key, so the event_id filter silently matches nothing on DELETE.
ALTER TABLE comments REPLICA IDENTITY FULL;

-- Idempotent: safe to run on local, staging, and prod in any order.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'comments'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE comments;
  END IF;
END $$;
