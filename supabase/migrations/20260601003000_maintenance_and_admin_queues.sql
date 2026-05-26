
-- ============================================================================
-- Source: 20260601007600_drop_duplicate_city_index.sql
-- ============================================================================

-- events_published_city_start_id_idx was created in 007001 but is identical to
-- events_published_feed_idx (same columns + WHERE predicate) from 006800.
-- Drop the newer duplicate; keep events_published_feed_idx.

DROP INDEX IF EXISTS public.events_published_city_start_id_idx;


-- ============================================================================
-- Source: 20260601007700_event_tag_queue_finished_at_idx.sql
-- ============================================================================

-- pg_stat_statements index_advisor: admin tag queue query (1278 calls, ~23 ms mean)
-- filters by status, orders by finished_at DESC — seq scan costs 1365→275 with this index.

CREATE INDEX IF NOT EXISTS event_tag_queue_finished_at_idx
  ON public.event_tag_queue (finished_at);


-- ============================================================================
-- Source: 20260601007800_fix_public_run_daily_maintenance.sql
-- ============================================================================

BEGIN;

-- Update private.run_daily_maintenance to include timezone refresh + trace pruning.
-- Previously the public wrapper duplicated the private logic AND added timezone refresh,
-- while trace_retention.sql only updated the private version with trace pruning.
-- This merge ensures the private function is the single source of truth.
CREATE OR REPLACE FUNCTION "private"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_event_tag_pruned          int;
  v_invite_request_pruned     int;
  v_invite_redemption_pruned  int;
  v_rec_pruned                int;
  v_ai_traces_pruned          int;
  v_extraction_traces_pruned  int;
BEGIN
  DELETE FROM public.event_tag_queue
  WHERE (status = 'dead'   AND finished_at < now() - interval '30 days')
     OR (status = 'failed' AND finished_at < now() - interval '7 days');
  GET DIAGNOSTICS v_event_tag_pruned = ROW_COUNT;

  DELETE FROM public.invite_request_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_request_pruned = ROW_COUNT;

  DELETE FROM public.invite_redemption_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_redemption_pruned = ROW_COUNT;

  DELETE FROM public.recommendation_signals
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_rec_pruned = ROW_COUNT;

  DELETE FROM public.event_ai_traces
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_ai_traces_pruned = ROW_COUNT;

  DELETE FROM public.source_extraction_traces
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_extraction_traces_pruned = ROW_COUNT;

  PERFORM private.refresh_timezone_names();

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',              v_event_tag_pruned,
    'invite_request_attempts_pruned',      v_invite_request_pruned,
    'invite_redemption_attempts_pruned',   v_invite_redemption_pruned,
    'recommendation_signals_pruned',       v_rec_pruned,
    'ai_traces_pruned',                    v_ai_traces_pruned,
    'extraction_traces_pruned',            v_extraction_traces_pruned,
    'timezone_names_refreshed',            true,
    'ran_at',                              now()
  );
END;
$$;

-- Replace the duplicated public wrapper with a thin SECURITY INVOKER delegate.
-- service_role has EXECUTE on private.run_daily_maintenance and USAGE on schema private
-- (granted in 20260601005600), so this call resolves correctly.
CREATE OR REPLACE FUNCTION "public"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY INVOKER
    SET "search_path" TO ''
    AS $$
BEGIN
  RETURN private.run_daily_maintenance();
END;
$$;

REVOKE ALL ON FUNCTION "public"."run_daily_maintenance"() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION "public"."run_daily_maintenance"() TO service_role;

COMMENT ON FUNCTION "private"."run_daily_maintenance"() IS 'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals, event_ai_traces, source_extraction_traces. Also refreshes private.timezone_names_cache. Invoked via public.run_daily_maintenance() by the cron-db-maintenance Railway service.';
COMMENT ON FUNCTION "public"."run_daily_maintenance"() IS 'Thin SECURITY INVOKER wrapper delegating to private.run_daily_maintenance(). Called by the db-maintenance edge function (service_role).';

COMMIT;


-- ============================================================================
-- Source: 20260601007900_fix_refresh_timezone_names_concurrent.sql
-- ============================================================================

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


-- ============================================================================
-- Source: 20260601008000_admin_delete_dead_queue.sql
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_deleted int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.source_scrape_queue
  WHERE id = p_queue_id AND status = 'dead';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted > 0;
END;
$$;

ALTER FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_deleted int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.event_tag_queue
  WHERE id = p_queue_id AND status = 'dead';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted > 0;
END;
$$;

ALTER FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_delete_dead_source_queue(p_queue_id); $$;

ALTER FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_delete_dead_tag_queue(p_queue_id); $$;

ALTER FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) OWNER TO "postgres";


REVOKE ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "authenticated";


REVOKE ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "authenticated";


REVOKE ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "service_role";


REVOKE ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "service_role";

COMMIT;


-- ============================================================================
-- Source: 20260601008100_admin_events_virtualized_counts.sql
-- ============================================================================

BEGIN;

-- ==========================================================================
-- Admin queue RPCs + exact counts for virtualized admin review.
-- Keeps list and facet queries aligned on the same keyword semantics.
--
-- Notes:
-- - List pagination is keyset-based on (created_at DESC, id DESC)
-- - Page size is clamped to [1, 500]
-- - total_count is computed before pagination and returned on every row
-- - Non-admin callers are blocked in both private and public wrappers
-- ==========================================================================

-- ---------------------------------------------------------------------------
-- Admin index support for keyset pagination and grouping paths.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS events_admin_city_created_idx
  ON public.events (city_id, created_at DESC, id);

CREATE INDEX IF NOT EXISTS events_admin_status_city_created_idx
  ON public.events (status, city_id, created_at DESC, id);

-- Existing indexes remain in place:
-- - events_admin_created_idx (created_at DESC, id)
-- - events_admin_status_created_idx (status, created_at DESC, id)
-- - events_search_vector_idx

-- ---------------------------------------------------------------------------
-- private.admin_events_enriched (security-definer)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.admin_events_enriched(
  p_status            text        DEFAULT NULL::text,
  p_city_id           uuid        DEFAULT NULL::uuid,
  p_city_is_null      boolean     DEFAULT NULL::boolean,
  p_keyword           text        DEFAULT NULL::text,
  p_after_created_at  timestamptz DEFAULT NULL::timestamptz,
  p_after_id          uuid        DEFAULT NULL::uuid,
  p_limit             int         DEFAULT 50
)
RETURNS TABLE (
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamptz,
  end_datetime          timestamptz,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               int,
  age_max               int,
  price                 numeric,
  is_free               boolean,
  source_url            text,
  source_name           text,
  source_id             uuid,
  images                jsonb,
  status                text,
  ai_confidence         numeric,
  ai_tag_provider       text,
  recurrence_info       jsonb,
  is_featured           boolean,
  view_count            int,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamptz,
  admin_last_edited_by  uuid,
  created_at            timestamptz,
  updated_at            timestamptz,
  ai_tag_model          text,
  ai_tag_status         text,
  total_count           bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH search_input AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE btrim(p_keyword)
      END AS kw,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::tsquery
        ELSE websearch_to_tsquery('english', btrim(p_keyword))
      END AS tsq,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE replace(replace(replace(btrim(p_keyword), '\\', '\\\\'), '%', '\\%'), '_', '\\_')
      END AS escaped_kw,
      LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500) AS page_size
  ),
  base AS (
    SELECT e.*
    FROM public.events e
    CROSS JOIN search_input si
    WHERE
      (p_status IS NULL OR e.status = p_status)
      AND (
        p_city_is_null IS NULL
        OR (p_city_is_null = true  AND e.city_id IS NULL)
        OR (p_city_is_null = false AND e.city_id IS NOT NULL)
      )
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (
        si.kw IS NULL
        OR (
          si.tsq IS NOT NULL
          AND numnode(si.tsq) > 0
          AND e.search_vector @@ si.tsq
        )
        OR (
          si.escaped_kw IS NOT NULL
          AND (si.tsq IS NULL OR numnode(si.tsq) = 0 OR length(si.kw) < 3)
          AND (
            e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
            OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
          )
        )
      )
  ),
  base_count AS (
    SELECT COUNT(*)::bigint AS total_count FROM base
  ),
  page AS (
    SELECT
      b.*, c.total_count
    FROM base b
    CROSS JOIN base_count c
    WHERE (
      p_after_created_at IS NULL
      OR (
        p_after_id IS NULL
        AND b.created_at < p_after_created_at
      )
      OR (
        p_after_id IS NOT NULL
        AND (b.created_at, b.id) < (p_after_created_at, p_after_id)
      )
    )
    ORDER BY b.created_at DESC, b.id DESC
    LIMIT (SELECT page_size FROM search_input)
  )
  SELECT
    p.id, p.title, p.description, p.start_datetime, p.end_datetime, p.timezone,
    p.venue_name, p.address, p.city_id, p.latitude, p.longitude,
    p.age_min, p.age_max, p.price, p.is_free,
    p.source_url, p.source_name, p.source_id, p.images, p.status,
    p.ai_confidence, p.ai_tag_provider, p.recurrence_info, p.is_featured, p.view_count,
    p.search_vector, p.admin_locked_fields, p.admin_last_edited_at, p.admin_last_edited_by,
    p.created_at, p.updated_at, p.ai_tag_model, p.ai_tag_status,
    p.total_count
  FROM page p;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- public.admin_events_enriched (security-invoker)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_events_enriched(
  p_status            text        DEFAULT NULL::text,
  p_city_id           uuid        DEFAULT NULL::uuid,
  p_city_is_null      boolean     DEFAULT NULL::boolean,
  p_keyword           text        DEFAULT NULL::text,
  p_after_created_at  timestamptz DEFAULT NULL::timestamptz,
  p_after_id          uuid        DEFAULT NULL::uuid,
  p_limit             int         DEFAULT 50
)
RETURNS TABLE (
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamptz,
  end_datetime          timestamptz,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               int,
  age_max               int,
  price                 numeric,
  is_free               boolean,
  source_url            text,
  source_name           text,
  source_id             uuid,
  images                jsonb,
  status                text,
  ai_confidence         numeric,
  ai_tag_provider       text,
  recurrence_info       jsonb,
  is_featured           boolean,
  view_count            int,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamptz,
  admin_last_edited_by  uuid,
  created_at            timestamptz,
  updated_at            timestamptz,
  ai_tag_model          text,
  ai_tag_status         text,
  total_count           bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_events_enriched(
    p_status, p_city_id, p_city_is_null, p_keyword,
    p_after_created_at, p_after_id, p_limit
  );
$$;

REVOKE EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- private.admin_event_facets (security-definer)
-- Grouped city/status counts with the same keyword normalization as list RPC.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.admin_event_facets(
  p_keyword text DEFAULT NULL::text
)
RETURNS TABLE (
  city_id uuid,
  status text,
  count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH search_input AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE btrim(p_keyword)
      END AS kw,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::tsquery
        ELSE websearch_to_tsquery('english', btrim(p_keyword))
      END AS tsq,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE replace(replace(replace(btrim(p_keyword), '\\', '\\\\'), '%', '\\%'), '_', '\\_')
      END AS escaped_kw
  )
  SELECT
    e.city_id,
    e.status,
    COUNT(*)::bigint AS count
  FROM public.events e
  CROSS JOIN search_input si
  WHERE
    (
      si.kw IS NULL
      OR (
        si.tsq IS NOT NULL
        AND numnode(si.tsq) > 0
        AND e.search_vector @@ si.tsq
      )
      OR (
        si.escaped_kw IS NOT NULL
        AND (si.tsq IS NULL OR numnode(si.tsq) = 0 OR length(si.kw) < 3)
        AND (
          e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
          OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
        )
      )
    )
  GROUP BY e.city_id, e.status
  ORDER BY e.city_id, e.status;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_event_facets(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.admin_event_facets(text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- public.admin_event_facets (security-invoker)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_event_facets(
  p_keyword text DEFAULT NULL::text
)
RETURNS TABLE (
  city_id uuid,
  status text,
  count bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_event_facets(p_keyword);
$$;

REVOKE EXECUTE ON FUNCTION public.admin_event_facets(text)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_event_facets(text)
  TO authenticated;

COMMIT;


-- ============================================================================
-- Source: 20260601008200_fix_lafayette_public_library_ical_source.sql
-- ============================================================================

DO $$
DECLARE
  lafayette_city_id uuid;
  existing_lpl_id uuid;
  existing_correct_id uuid;
  correct_url text := 'https://lafayettela.libcal.com/ical_subscribe.php?src=p&cid=11334';
BEGIN
  SELECT id
  INTO lafayette_city_id
  FROM public.cities
  WHERE slug = 'lafayette';

  SELECT id
  INTO existing_correct_id
  FROM public.event_sources
  WHERE url = correct_url
  ORDER BY created_at
  LIMIT 1;

  SELECT id
  INTO existing_lpl_id
  FROM public.event_sources
  WHERE name = 'Lafayette Public Library'
  ORDER BY created_at
  LIMIT 1;

  IF existing_lpl_id IS NOT NULL AND existing_correct_id IS NULL THEN
    UPDATE public.event_sources
    SET
      url = correct_url,
      source_type = 'ical',
      city_id = lafayette_city_id,
      scrape_interval_hours = 6,
      date_window_days = NULL,
      notes = 'Library story times and kids programming via LibCal iCal feed',
      updated_at = now()
    WHERE id = existing_lpl_id;
  ELSIF existing_correct_id IS NOT NULL THEN
    UPDATE public.event_sources
    SET
      name = 'Lafayette Public Library',
      source_type = 'ical',
      city_id = lafayette_city_id,
      is_active = true,
      scrape_interval_hours = 6,
      date_window_days = NULL,
      notes = 'Library story times and kids programming via LibCal iCal feed',
      updated_at = now()
    WHERE id = existing_correct_id;

    UPDATE public.event_sources
    SET
      is_active = false,
      notes = 'Replaced by Lafayette Public Library LibCal iCal feed.',
      updated_at = now()
    WHERE name = 'Lafayette Public Library'
      AND id <> existing_correct_id;
  ELSE
    INSERT INTO public.event_sources (
      name,
      url,
      source_type,
      city_id,
      is_active,
      scrape_interval_hours,
      date_window_days,
      notes
    )
    VALUES (
      'Lafayette Public Library',
      correct_url,
      'ical',
      lafayette_city_id,
      true,
      6,
      NULL,
      'Library story times and kids programming via LibCal iCal feed'
    );
  END IF;
END $$;


-- ============================================================================
-- Source: 20260601008300_repair_dead_queue_delete_rpcs.sql
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_deleted int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.source_scrape_queue
  WHERE id = p_queue_id AND status = 'dead';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted > 0;
END;
$$;

ALTER FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_deleted int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.event_tag_queue
  WHERE id = p_queue_id AND status = 'dead';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted > 0;
END;
$$;

ALTER FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "sql" SECURITY INVOKER
    SET "search_path" TO ''
    AS $$ SELECT private.admin_delete_dead_source_queue(p_queue_id); $$;

ALTER FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "sql" SECURITY INVOKER
    SET "search_path" TO ''
    AS $$ SELECT private.admin_delete_dead_tag_queue(p_queue_id); $$;

ALTER FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) OWNER TO "postgres";


REVOKE ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "authenticated";


REVOKE ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "authenticated";


REVOKE ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "service_role";


REVOKE ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "service_role";

DO $$
BEGIN
  IF to_regprocedure('public.admin_delete_dead_source_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_source_queue public RPC was not created';
  END IF;
  IF to_regprocedure('public.admin_delete_dead_tag_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_tag_queue public RPC was not created';
  END IF;
  IF to_regprocedure('private.admin_delete_dead_source_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_source_queue private RPC was not created';
  END IF;
  IF to_regprocedure('private.admin_delete_dead_tag_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_tag_queue private RPC was not created';
  END IF;

  RAISE NOTICE 'admin_delete_dead_*_queue RPCs verified';
END $$;

COMMIT;


-- ============================================================================
-- Source: 20260601008400_admin_mutation_audit_rpcs.sql
-- ============================================================================

CREATE OR REPLACE FUNCTION private.admin_set_user_access(
  p_user_id uuid,
  p_is_enabled boolean,
  p_disabled_reason text DEFAULT NULL
) RETURNS public.user_access
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  before_row public.user_access%ROWTYPE;
  updated_row public.user_access%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_ADMIN_REQUIRED';
  END IF;

  IF p_user_id = auth.uid() AND NOT p_is_enabled THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_SELF_DISABLE';
  END IF;

  SELECT *
    INTO before_row
    FROM public.user_access
   WHERE user_id = p_user_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_NOT_FOUND';
  END IF;

  UPDATE public.user_access
     SET is_enabled = p_is_enabled,
         enabled_at = CASE
           WHEN p_is_enabled THEN COALESCE(public.user_access.enabled_at, now())
           ELSE public.user_access.enabled_at
         END,
         disabled_at = CASE WHEN p_is_enabled THEN NULL ELSE now() END,
         disabled_reason = CASE
           WHEN p_is_enabled THEN NULL
           ELSE NULLIF(btrim(COALESCE(p_disabled_reason, '')), '')
         END,
         updated_at = now()
   WHERE user_id = p_user_id
   RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    CASE WHEN p_is_enabled THEN 'user_access.enable' ELSE 'user_access.disable' END,
    'user_access',
    p_user_id,
    jsonb_build_object(
      'previous', to_jsonb(before_row),
      'is_enabled', p_is_enabled,
      'disabled_reason', updated_row.disabled_reason
    )
  );

  RETURN updated_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_user_access(
  p_user_id uuid,
  p_is_enabled boolean,
  p_disabled_reason text DEFAULT NULL
) RETURNS public.user_access
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_set_user_access(p_user_id, p_is_enabled, p_disabled_reason);
$$;

CREATE OR REPLACE FUNCTION private.admin_set_event_status(
  p_event_id uuid,
  p_status text
) RETURNS public.events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  before_row public.events%ROWTYPE;
  updated_row public.events%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  IF p_status <> ALL (ARRAY['draft', 'published', 'rejected', 'archived']) THEN
    RAISE EXCEPTION 'ADMIN_EVENT_INVALID_STATUS';
  END IF;

  SELECT *
    INTO before_row
    FROM public.events
   WHERE id = p_event_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_EVENT_NOT_FOUND';
  END IF;

  UPDATE public.events
     SET status = p_status,
         admin_last_edited_at = now(),
         admin_last_edited_by = auth.uid(),
         updated_at = now()
   WHERE id = p_event_id
   RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'event.status.update',
    'event',
    p_event_id,
    jsonb_build_object('previous_status', before_row.status, 'status', p_status)
  );

  RETURN updated_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_event_status(
  p_event_id uuid,
  p_status text
) RETURNS public.events
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_set_event_status(p_event_id, p_status);
$$;

CREATE OR REPLACE FUNCTION private.admin_batch_set_event_status(
  p_event_ids uuid[],
  p_status text
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
  previous_rows jsonb;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  IF p_status <> ALL (ARRAY['draft', 'published', 'rejected', 'archived']) THEN
    RAISE EXCEPTION 'ADMIN_EVENT_INVALID_STATUS';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.id), '[]'::jsonb)
    INTO previous_rows
    FROM public.events e
   WHERE e.id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  UPDATE public.events
     SET status = p_status,
         admin_last_edited_at = now(),
         admin_last_edited_by = auth.uid(),
         updated_at = now()
   WHERE id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'event.status.batch_update',
    'events',
    jsonb_build_object(
      'event_ids', to_jsonb(COALESCE(p_event_ids, '{}'::uuid[])),
      'status', p_status,
      'affected_count', affected,
      'previous', previous_rows
    )
  );

  RETURN affected;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_batch_set_event_status(
  p_event_ids uuid[],
  p_status text
) RETURNS integer
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT private.admin_batch_set_event_status(p_event_ids, p_status);
$$;

CREATE OR REPLACE FUNCTION private.admin_delete_events(
  p_event_ids uuid[]
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
  previous_rows jsonb;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.id), '[]'::jsonb)
    INTO previous_rows
    FROM public.events e
   WHERE e.id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  DELETE FROM public.events
   WHERE id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'event.delete',
    'events',
    jsonb_build_object(
      'event_ids', to_jsonb(COALESCE(p_event_ids, '{}'::uuid[])),
      'affected_count', affected,
      'previous', previous_rows
    )
  );

  RETURN affected;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_events(
  p_event_ids uuid[]
) RETURNS integer
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT private.admin_delete_events(p_event_ids);
$$;

CREATE OR REPLACE FUNCTION private.admin_create_source(
  p_source jsonb
) RETURNS public.event_sources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  source_payload jsonb := COALESCE(p_source, '{}'::jsonb);
  created_row public.event_sources%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_ADMIN_REQUIRED';
  END IF;

  IF NULLIF(btrim(source_payload->>'name'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NAME_REQUIRED';
  END IF;

  IF NULLIF(btrim(source_payload->>'url'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_URL_REQUIRED';
  END IF;

  INSERT INTO public.event_sources (
    name,
    url,
    source_type,
    extraction_mode,
    city_id,
    is_active,
    auto_approve,
    scrape_interval_hours,
    last_scraped_at,
    last_status,
    error_count,
    notes,
    date_window_days
  )
  VALUES (
    btrim(source_payload->>'name'),
    btrim(source_payload->>'url'),
    COALESCE(NULLIF(btrim(source_payload->>'source_type'), ''), 'website'),
    COALESCE(NULLIF(btrim(source_payload->>'extraction_mode'), ''), 'deterministic')::public.source_extraction_mode,
    CASE
      WHEN source_payload ? 'city_id' AND jsonb_typeof(source_payload->'city_id') <> 'null' AND NULLIF(btrim(source_payload->>'city_id'), '') IS NOT NULL
        THEN (source_payload->>'city_id')::uuid
      ELSE NULL
    END,
    COALESCE((source_payload->>'is_active')::boolean, true),
    COALESCE((source_payload->>'auto_approve')::boolean, false),
    COALESCE((source_payload->>'scrape_interval_hours')::integer, 24),
    CASE
      WHEN source_payload ? 'last_scraped_at' AND jsonb_typeof(source_payload->'last_scraped_at') <> 'null'
        THEN (source_payload->>'last_scraped_at')::timestamptz
      ELSE NULL
    END,
    COALESCE(NULLIF(btrim(source_payload->>'last_status'), ''), 'pending'),
    COALESCE((source_payload->>'error_count')::integer, 0),
    CASE
      WHEN source_payload ? 'notes' AND jsonb_typeof(source_payload->'notes') <> 'null'
        THEN source_payload->>'notes'
      ELSE NULL
    END,
    CASE
      WHEN source_payload ? 'date_window_days' AND jsonb_typeof(source_payload->'date_window_days') <> 'null'
        THEN (source_payload->>'date_window_days')::integer
      ELSE NULL
    END
  )
  RETURNING * INTO created_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'source.create',
    'event_source',
    created_row.id,
    jsonb_build_object('source', to_jsonb(created_row))
  );

  RETURN created_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_source(
  p_source jsonb
) RETURNS public.event_sources
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_create_source(p_source);
$$;

CREATE OR REPLACE FUNCTION private.admin_update_source(
  p_source_id uuid,
  p_patch jsonb
) RETURNS public.event_sources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  patch jsonb := COALESCE(p_patch, '{}'::jsonb);
  before_row public.event_sources%ROWTYPE;
  updated_row public.event_sources%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_ADMIN_REQUIRED';
  END IF;

  IF patch ? 'name' AND NULLIF(btrim(patch->>'name'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NAME_REQUIRED';
  END IF;

  IF patch ? 'url' AND NULLIF(btrim(patch->>'url'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_URL_REQUIRED';
  END IF;

  SELECT *
    INTO before_row
    FROM public.event_sources
   WHERE id = p_source_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NOT_FOUND';
  END IF;

  UPDATE public.event_sources
     SET name = CASE WHEN patch ? 'name' THEN btrim(patch->>'name') ELSE name END,
         url = CASE WHEN patch ? 'url' THEN btrim(patch->>'url') ELSE url END,
         source_type = CASE WHEN patch ? 'source_type' THEN patch->>'source_type' ELSE source_type END,
         extraction_mode = CASE WHEN patch ? 'extraction_mode' THEN (patch->>'extraction_mode')::public.source_extraction_mode ELSE extraction_mode END,
         city_id = CASE
           WHEN patch ? 'city_id' AND jsonb_typeof(patch->'city_id') = 'null' THEN NULL
           WHEN patch ? 'city_id' AND NULLIF(btrim(patch->>'city_id'), '') IS NULL THEN NULL
           WHEN patch ? 'city_id' THEN (patch->>'city_id')::uuid
           ELSE city_id
         END,
         is_active = CASE WHEN patch ? 'is_active' THEN (patch->>'is_active')::boolean ELSE is_active END,
         auto_approve = CASE WHEN patch ? 'auto_approve' THEN (patch->>'auto_approve')::boolean ELSE auto_approve END,
         scrape_interval_hours = CASE WHEN patch ? 'scrape_interval_hours' THEN (patch->>'scrape_interval_hours')::integer ELSE scrape_interval_hours END,
         last_scraped_at = CASE
           WHEN patch ? 'last_scraped_at' AND jsonb_typeof(patch->'last_scraped_at') = 'null' THEN NULL
           WHEN patch ? 'last_scraped_at' THEN (patch->>'last_scraped_at')::timestamptz
           ELSE last_scraped_at
         END,
         last_status = CASE
           WHEN patch ? 'last_status' AND jsonb_typeof(patch->'last_status') = 'null' THEN NULL
           WHEN patch ? 'last_status' THEN patch->>'last_status'
           ELSE last_status
         END,
         error_count = CASE WHEN patch ? 'error_count' THEN (patch->>'error_count')::integer ELSE error_count END,
         notes = CASE
           WHEN patch ? 'notes' AND jsonb_typeof(patch->'notes') = 'null' THEN NULL
           WHEN patch ? 'notes' THEN patch->>'notes'
           ELSE notes
         END,
         date_window_days = CASE
           WHEN patch ? 'date_window_days' AND jsonb_typeof(patch->'date_window_days') = 'null' THEN NULL
           WHEN patch ? 'date_window_days' THEN (patch->>'date_window_days')::integer
           ELSE date_window_days
         END,
         updated_at = now()
   WHERE id = p_source_id
   RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'source.update',
    'event_source',
    p_source_id,
    jsonb_build_object('previous', to_jsonb(before_row), 'patch', patch)
  );

  RETURN updated_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_source(
  p_source_id uuid,
  p_patch jsonb
) RETURNS public.event_sources
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_update_source(p_source_id, p_patch);
$$;

REVOKE EXECUTE ON FUNCTION private.admin_set_user_access(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_set_user_access(uuid, boolean, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_set_user_access(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_access(uuid, boolean, text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_set_event_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_set_event_status(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_set_event_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_event_status(uuid, text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_batch_set_event_status(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_batch_set_event_status(uuid[], text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_batch_set_event_status(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_batch_set_event_status(uuid[], text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_delete_events(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_delete_events(uuid[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_delete_events(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_events(uuid[]) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_create_source(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_create_source(jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_create_source(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_source(jsonb) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_update_source(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_update_source(uuid, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_update_source(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_source(uuid, jsonb) TO authenticated, service_role;

