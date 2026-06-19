-- Rollback for 20260601003000_maintenance_and_admin_queues.sql
--
-- The UP migration is a bundle of 9 source migrations (header comments mark each):
--   007600 drop_duplicate_city_index
--   007700 event_tag_queue_finished_at_idx
--   007800 fix_public_run_daily_maintenance
--   007900 fix_refresh_timezone_names_concurrent
--   008000 admin_delete_dead_queue
--   008100 admin_events_virtualized_counts
--   008200 fix_lafayette_public_library_ical_source   <-- IRREVERSIBLE (data); see STOP
--   008300 repair_dead_queue_delete_rpcs
--   008400 admin_mutation_audit_rpcs
--
-- This down reverts in REVERSE source order (008400 -> 007600). Effects are
-- inverted as follows; prior-definition sources cited inline:
--
--   INTRODUCED by 003000 (inverse = DROP):
--     * indexes event_tag_queue_finished_at_idx, events_admin_city_created_idx,
--       events_admin_status_city_created_idx
--       (confirmed absent in baseline / 001000 / 002000)
--     * private+public admin_delete_dead_source_queue / admin_delete_dead_tag_queue
--       (absent in baseline / 001000 / 002000)
--     * private+public admin_event_facets (absent everywhere prior)
--     * private+public admin_set_user_access, admin_set_event_status,
--       admin_batch_set_event_status, admin_delete_events, admin_create_source,
--       admin_update_source (all absent in baseline / 001000 / 002000)
--
--   REPLACED by 003000 (inverse = restore PRIOR body):
--     * private.run_daily_maintenance  -> prior body: 20260601000000_schema_baseline.sql:3260-3295
--                                         prior COMMENT:                              :3301
--                                         prior grants:                               :6321-6322
--     * public.run_daily_maintenance   -> prior body: 20260601000000_schema_baseline.sql:4115-4156
--                                         prior COMMENT:                              :4162
--                                         prior grants:                               :6585-6586
--                                         (NOTE: prior public fn was SECURITY DEFINER, not INVOKER)
--     * private.refresh_timezone_names -> prior body: 20260601000000_schema_baseline.sql:3139-3144
--                                         (prior was LANGUAGE sql, unconditional CONCURRENTLY)
--     * private.admin_events_enriched  -> prior body: 20260601002000_event_ingestion_admin_foundation.sql:511-600
--     * public.admin_events_enriched   -> prior body: 20260601002000_event_ingestion_admin_foundation.sql:610-664
--                                         (prior public fn was LANGUAGE sql VOLATILE; 003000 made it STABLE)
--       Signatures of both admin_events_enriched overloads are IDENTICAL across
--       002000 and 003000, so CREATE OR REPLACE replaced them in place (no extra
--       overload to drop) -- restoring the prior body is the correct inverse.
--
-- ============================================================================
-- STOP / IRREVERSIBLE ITEMS (NOT inverted below -- read before running):
-- ============================================================================
--
-- (A) Section 007600: `DROP INDEX IF EXISTS public.events_published_city_start_id_idx`.
--     The actual CREATE INDEX statement for events_published_city_start_id_idx
--     exists NOWHERE in the committed migrations (not baseline, 001000, or 002000).
--     The squashed baseline already reflects the post-drop end-state, so this DROP
--     is effectively a no-op against baseline -- the index only existed in pre-squash
--     live history. The UP and 002000 comments give CONFLICTING provenance ("007001"
--     vs "006800") and describe it only as "identical to events_published_feed_idx"
--     (001000:482-484 = ON public.events (city_id, start_datetime, id) WHERE status='published').
--     A rollback must NOT guess index DDL. This index is NOT recreated here.
--     If you genuinely need it back, recover the exact definition from a pre-squash
--     dump and recreate it manually.
--
-- (B) Section 008200: the Lafayette Public Library iCal source `DO $$` block
--     UPDATEs an existing public.event_sources row (or INSERTs a new one) and may
--     deactivate sibling rows. The pre-migration row state (url/source_type/city_id/
--     is_active/scrape_interval_hours/date_window_days/notes for the affected
--     event_sources rows) is unknown and unrecoverable from the migration text.
--     This is a DATA mutation, not schema -- it is NOT reverted here. Restoring it
--     would require knowing the prior row values.
--
-- ORDERING HAZARDS:
--   * public wrappers depend on the private SECURITY DEFINER functions; drop
--     public wrappers BEFORE the private functions (done below).
--   * Restoring public.run_daily_maintenance to its baseline SECURITY DEFINER body
--     references private.refresh_timezone_names(); that private function still
--     exists after this rollback (we restore its prior body, we do not drop it),
--     so the reference resolves.
--   * admin_events_enriched: drop is NOT used (signature unchanged) -- we CREATE OR
--     REPLACE back to the 002000 body. Do not DROP it or the public wrapper breaks.

BEGIN;

-- ============================================================================
-- 008400 (reverse): DROP the 6 admin mutation/audit RPC pairs introduced here.
-- INTRODUCED by 003000 -> inverse is DROP. (public wrappers first, then private)
-- ============================================================================
DROP FUNCTION IF EXISTS public.admin_update_source(uuid, jsonb);
DROP FUNCTION IF EXISTS private.admin_update_source(uuid, jsonb);

DROP FUNCTION IF EXISTS public.admin_create_source(jsonb);
DROP FUNCTION IF EXISTS private.admin_create_source(jsonb);

DROP FUNCTION IF EXISTS public.admin_delete_events(uuid[]);
DROP FUNCTION IF EXISTS private.admin_delete_events(uuid[]);

DROP FUNCTION IF EXISTS public.admin_batch_set_event_status(uuid[], text);
DROP FUNCTION IF EXISTS private.admin_batch_set_event_status(uuid[], text);

DROP FUNCTION IF EXISTS public.admin_set_event_status(uuid, text);
DROP FUNCTION IF EXISTS private.admin_set_event_status(uuid, text);

DROP FUNCTION IF EXISTS public.admin_set_user_access(uuid, boolean, text);
DROP FUNCTION IF EXISTS private.admin_set_user_access(uuid, boolean, text);

-- ============================================================================
-- 008300 (reverse): no separate inverse.
-- 008300 only re-CREATE OR REPLACE'd the dead-queue RPCs that 008000 introduced
-- (changing public wrappers to SECURITY INVOKER) and ran a verification DO block.
-- Those functions are dropped wholesale below (008000 reverse), so nothing to do.
-- ============================================================================

-- ============================================================================
-- 008200 (reverse): IRREVERSIBLE DATA SEED -- see STOP (B). Intentionally NOT reverted.
-- ============================================================================

-- ============================================================================
-- 008100 (reverse):
--   - DROP admin_event_facets pair (INTRODUCED -> DROP)
--   - RESTORE admin_events_enriched pair to prior 002000 body (REPLACED)
--   - DROP the two admin indexes introduced here (INTRODUCED -> DROP)
-- ============================================================================

-- admin_event_facets: introduced by 003000 -> DROP (public wrapper first).
DROP FUNCTION IF EXISTS public.admin_event_facets(text);
DROP FUNCTION IF EXISTS private.admin_event_facets(text);

-- admin_events_enriched: REPLACED -> restore prior body from
-- 20260601002000_event_ingestion_admin_foundation.sql:511-600 (private) and :610-664 (public).
-- Signatures are identical, so CREATE OR REPLACE swaps the body back in place.
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
  WITH filtered AS (
    SELECT e.*
    FROM public.events e
    WHERE
      (p_status IS NULL OR e.status = p_status)
      AND (
        p_city_is_null IS NULL
        OR (p_city_is_null = true  AND e.city_id IS NULL)
        OR (p_city_is_null = false AND e.city_id IS NOT NULL)
      )
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (
        p_keyword IS NULL
        OR e.title       ILIKE '%' || p_keyword || '%'
        OR e.description ILIKE '%' || p_keyword || '%'
      )
      AND (
        p_after_created_at IS NULL
        OR (e.created_at, e.id) < (p_after_created_at, p_after_id)
      )
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 200)
  )
  SELECT
    f.id, f.title, f.description, f.start_datetime, f.end_datetime, f.timezone,
    f.venue_name, f.address, f.city_id, f.latitude, f.longitude,
    f.age_min, f.age_max, f.price, f.is_free,
    f.source_url, f.source_name, f.source_id, f.images, f.status,
    f.ai_confidence, f.ai_tag_provider, f.recurrence_info, f.is_featured, f.view_count,
    f.search_vector, f.admin_locked_fields, f.admin_last_edited_at, f.admin_last_edited_by,
    f.created_at, f.updated_at, f.ai_tag_model, f.ai_tag_status,
    COUNT(*) OVER ()::bigint AS total_count
  FROM filtered f;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  TO authenticated, service_role;

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
VOLATILE
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

-- Indexes introduced by 008100 -> DROP.
DROP INDEX IF EXISTS public.events_admin_status_city_created_idx;
DROP INDEX IF EXISTS public.events_admin_city_created_idx;

-- ============================================================================
-- 008000 (reverse): DROP the dead-queue delete RPCs introduced here.
-- (008300 re-created the same functions; dropping once removes the end-state.)
-- INTRODUCED by 003000 -> inverse is DROP. (public wrappers first, then private)
-- ============================================================================
DROP FUNCTION IF EXISTS public.admin_delete_dead_tag_queue(bigint);
DROP FUNCTION IF EXISTS public.admin_delete_dead_source_queue(bigint);
DROP FUNCTION IF EXISTS private.admin_delete_dead_tag_queue(bigint);
DROP FUNCTION IF EXISTS private.admin_delete_dead_source_queue(bigint);

-- ============================================================================
-- 007900 (reverse): RESTORE private.refresh_timezone_names to its prior baseline
-- body (20260601000000_schema_baseline.sql:3139-3144): LANGUAGE sql, unconditional
-- CONCURRENTLY. REPLACED -> restore prior body.
-- NOTE: the prior body assumes the matview is already populated; 007900 itself ran
-- a one-time REFRESH at migration time, so the cache is populated and this body works.
-- ============================================================================
CREATE OR REPLACE FUNCTION "private"."refresh_timezone_names"() RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  REFRESH MATERIALIZED VIEW CONCURRENTLY private.timezone_names_cache;
$$;

ALTER FUNCTION "private"."refresh_timezone_names"() OWNER TO "postgres";

-- ============================================================================
-- 007800 (reverse): RESTORE both run_daily_maintenance functions to their prior
-- baseline bodies, COMMENTs, and grants.
--   private -> 20260601000000_schema_baseline.sql:3260-3301 (+ grants :6321-6322)
--   public  -> 20260601000000_schema_baseline.sql:4115-4162 (+ grants :6585-6586)
-- The prior public body was SECURITY DEFINER (003000 changed it to a thin INVOKER
-- delegate); restore the DEFINER body verbatim. REPLACED -> restore prior body.
-- ============================================================================
CREATE OR REPLACE FUNCTION "private"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_event_tag_pruned     int;
  v_invite_request_pruned int;
  v_invite_redemption_pruned int;
  v_rec_pruned           int;
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

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',          v_event_tag_pruned,
    'invite_request_attempts_pruned',  v_invite_request_pruned,
    'invite_redemption_attempts_pruned', v_invite_redemption_pruned,
    'recommendation_signals_pruned',   v_rec_pruned,
    'ran_at',                          now()
  );
END;
$$;

ALTER FUNCTION "private"."run_daily_maintenance"() OWNER TO "postgres";

COMMENT ON FUNCTION "private"."run_daily_maintenance"() IS 'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals. Invoked by the cron-db-maintenance Railway service via the db-maintenance edge function.';

REVOKE ALL ON FUNCTION "private"."run_daily_maintenance"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."run_daily_maintenance"() TO "service_role";

CREATE OR REPLACE FUNCTION "public"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_event_tag_pruned         int;
  v_invite_request_pruned    int;
  v_invite_redemption_pruned int;
  v_rec_pruned               int;
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

  -- Refresh the timezone names materialized view cache. Cheap + idempotent.
  -- Previously scheduled weekly via pg_cron; folded here to drop the
  -- separate cron entry.
  PERFORM private.refresh_timezone_names();

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',            v_event_tag_pruned,
    'invite_request_attempts_pruned',    v_invite_request_pruned,
    'invite_redemption_attempts_pruned', v_invite_redemption_pruned,
    'recommendation_signals_pruned',     v_rec_pruned,
    'timezone_names_refreshed',          true,
    'ran_at',                            now()
  );
END;
$$;

ALTER FUNCTION "public"."run_daily_maintenance"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."run_daily_maintenance"() IS 'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals. Also refreshes private.timezone_names_cache (folded in from the unscheduled refresh-timezone-names pg_cron job). Invoked by cron-db-maintenance Railway service via the db-maintenance edge function.';

REVOKE ALL ON FUNCTION "public"."run_daily_maintenance"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."run_daily_maintenance"() TO "service_role";

-- ============================================================================
-- 007700 (reverse): DROP the index introduced here. INTRODUCED -> DROP.
-- ============================================================================
DROP INDEX IF EXISTS public.event_tag_queue_finished_at_idx;

-- ============================================================================
-- 007600 (reverse): IRREVERSIBLE -- see STOP (A). The dropped index
-- events_published_city_start_id_idx has no recoverable CREATE statement in the
-- committed migrations and is NOT recreated here.
-- ============================================================================

COMMIT;
