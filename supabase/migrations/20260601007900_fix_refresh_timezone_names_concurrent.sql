BEGIN;

-- CONCURRENTLY requires the matview to be populated; WITH NO DATA means it
-- starts empty and the first refresh always fails with code 0A000.
-- Fall back to a blocking refresh when empty, then use CONCURRENTLY thereafter.
CREATE OR REPLACE FUNCTION "private"."refresh_timezone_names"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM private.timezone_names_cache LIMIT 1) THEN
    REFRESH MATERIALIZED VIEW CONCURRENTLY private.timezone_names_cache;
  ELSE
    REFRESH MATERIALIZED VIEW private.timezone_names_cache;
  END IF;
END;
$$;

-- Populate the matview immediately so CONCURRENTLY works on the first cron run.
REFRESH MATERIALIZED VIEW private.timezone_names_cache;

COMMIT;
