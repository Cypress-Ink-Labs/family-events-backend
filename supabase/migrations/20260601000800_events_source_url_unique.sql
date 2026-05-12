-- Add a partial UNIQUE index on (source_id, source_url) so concurrent runs of
-- the same source (manual + cron, retries, recovery from edge timeout) cannot
-- double-insert. The in-memory dedup index in process-source.ts only sees rows
-- that existed *before* the run started; a second worker that opens its index
-- mid-flight can race past it.
--
-- Partial: only constrains rows where source_url IS NOT NULL. Manual events
-- always have NULL source_url and should remain freely insertable.
--
-- Backfill note: any pre-existing duplicates would block the index creation.
-- The DO block below collapses them by keeping the lowest-id row per
-- (source_id, source_url) pair, deleting the rest. If your data is clean this
-- is a no-op; if duplicates exist, run the SELECT first to confirm what would
-- be removed.

DO $$
DECLARE
  duplicate_count int;
BEGIN
  SELECT count(*) INTO duplicate_count
  FROM (
    SELECT source_id, source_url, count(*) AS c
    FROM public.events
    WHERE source_url IS NOT NULL
    GROUP BY source_id, source_url
    HAVING count(*) > 1
  ) dups;

  IF duplicate_count > 0 THEN
    RAISE NOTICE 'events_source_url_unique: collapsing % duplicate (source_id, source_url) pairs', duplicate_count;
    DELETE FROM public.events e
    USING (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY source_id, source_url
          ORDER BY created_at, id
        ) AS rn
      FROM public.events
      WHERE source_url IS NOT NULL
    ) ranked
    WHERE e.id = ranked.id AND ranked.rn > 1;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS events_source_id_source_url_uniq
  ON public.events (source_id, source_url)
  WHERE source_url IS NOT NULL;

COMMENT ON INDEX public.events_source_id_source_url_uniq IS
  'Idempotency for scrape-source imports. Backs upsert(... onConflict source_id,source_url).';
