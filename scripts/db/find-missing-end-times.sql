-- Find events with missing end_datetime
-- Run with: supabase db execute --file scripts/db/find-missing-end-times.sql
-- Or via psql against the remote database

-- Summary statistics
SELECT
  COUNT(*) FILTER (WHERE end_datetime IS NULL AND start_datetime IS NOT NULL) AS missing_end_time,
  COUNT(*) FILTER (WHERE end_datetime IS NOT NULL) AS has_end_time,
  COUNT(*) AS total_events,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE end_datetime IS NULL AND start_datetime IS NOT NULL) / NULLIF(COUNT(*), 0),
    1
  ) AS pct_missing
FROM events;

-- Detailed list of events missing end_datetime
SELECT
  id,
  title,
  start_datetime,
  end_datetime,
  source_url,
  created_at
FROM events
WHERE end_datetime IS NULL
  AND start_datetime IS NOT NULL
ORDER BY start_datetime DESC
LIMIT 50;
