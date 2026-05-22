-- collect-db-evidence.sql
-- Read-only diagnostic queries for production evidence gathering.
-- Run as: psql "$DB_URL" -f scripts/db/collect-db-evidence.sql
-- Never commit captured output.

-- ============================================================
-- pg_stat_statements: top 50 by total_exec_time
-- ============================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
    RAISE NOTICE 'pg_stat_statements available';
  ELSE
    RAISE NOTICE 'pg_stat_statements NOT installed — skipping';
  END IF;
END $$;

SELECT
  LEFT(query, 120) AS query_excerpt,
  calls,
  ROUND(total_exec_time::numeric, 2) AS total_ms,
  ROUND(mean_exec_time::numeric, 2) AS mean_ms,
  ROUND(stddev_exec_time::numeric, 2) AS stddev_ms,
  rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 50;

-- Top 50 by calls
SELECT
  LEFT(query, 120) AS query_excerpt,
  calls,
  ROUND(total_exec_time::numeric, 2) AS total_ms,
  ROUND(mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 50;

-- ============================================================
-- pg_stat_user_indexes
-- ============================================================
SELECT
  schemaname,
  relname AS table_name,
  indexrelname AS index_name,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC
LIMIT 100;

-- ============================================================
-- pg_stat_user_tables
-- ============================================================
SELECT
  schemaname,
  relname AS table_name,
  n_live_tup,
  n_dead_tup,
  n_mod_since_analyze,
  last_autovacuum,
  last_autoanalyze,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 50;

-- ============================================================
-- Constraint pre-validation (for NOT VALID constraints)
-- These must return 0 before running VALIDATE CONSTRAINT migrations.
-- ============================================================
SELECT 'events_age_range_chk violation count' AS check_name,
  COUNT(*) AS violations
FROM public.events
WHERE NOT (
  (age_min IS NULL OR age_min >= 0)
  AND (age_max IS NULL OR age_max >= 0)
  AND (age_min IS NULL OR age_max IS NULL OR age_min <= age_max)
);

SELECT 'events_lat_lon_chk violation count' AS check_name,
  COUNT(*) AS violations
FROM public.events
WHERE NOT (
  (latitude IS NULL OR latitude BETWEEN -90 AND 90)
  AND (longitude IS NULL OR longitude BETWEEN -180 AND 180)
);

SELECT 'events_price_chk violation count' AS check_name,
  COUNT(*) AS violations
FROM public.events
WHERE NOT (price IS NULL OR price >= 0);

SELECT 'user_profiles_child_age_chk violation count' AS check_name,
  COUNT(*) AS violations
FROM public.user_profiles
WHERE NOT (child_age IS NULL OR child_age BETWEEN 0 AND 18);

SELECT 'invite_codes_used_count_chk violation count' AS check_name,
  COUNT(*) AS violations
FROM public.invite_codes
WHERE NOT (used_count <= max_uses);

SELECT 'event_sources_scrape_interval_chk violation count' AS check_name,
  COUNT(*) AS violations
FROM public.event_sources
WHERE NOT (scrape_interval_hours IS NULL OR scrape_interval_hours BETWEEN 1 AND 720);

-- ============================================================
-- EXPLAIN templates (fill in params before running)
-- ============================================================

/*
-- search_events
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM public.search_events(
  p_city_id := NULL,
  p_keyword := 'family concert',
  p_limit   := 24
);

-- events_enriched_v2
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM public.events_enriched_v2(
  p_city_id := '<city-uuid>',
  p_limit   := 24
);

-- admin_events_enriched
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM public.admin_events_enriched(
  p_limit := 50
);

-- plan_events_for_user
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM public.plan_events_for_user(
  p_user_id := '<user-uuid>'
);

-- due_event_sources
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM public.due_event_sources(p_limit := 100);

-- private.claim_tag_queue_batch
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM private.claim_tag_queue_batch(p_limit := 5);

-- private.claim_source_scrape_queue_batch
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM private.claim_source_scrape_queue_batch(p_limit := 1);
*/
