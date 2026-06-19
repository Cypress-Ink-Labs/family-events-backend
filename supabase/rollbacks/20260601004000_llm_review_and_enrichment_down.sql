-- Rollback for 20260601004000_llm_review_and_enrichment.sql
--
-- The UP migration is a squash of nine source blocks (timestamps shown in its
-- own "-- Source:" banners), even though the file itself is timestamped
-- 20260601004000:
--   008500 llm_event_review_processing          (enums, columns, queue/traces
--                                                 tables, view, RLS, queue RPCs,
--                                                 admin processing-mode RPCs,
--                                                 admin_update_event_status,
--                                                 admin_events_enriched +2 args,
--                                                 bulk_import_scrape_events rewrite,
--                                                 apply_event_llm_review_decision)
--   008600 admin_update_source                  (add processing_mode CASE branch)
--   008700 fix_bulk_source_updates_safe_where    (admin_bulk_* WHERE id IS NOT NULL)
--   008800 enrichment_claim_city_centroid_coords (list_events_needing_enrichment v2)
--   008900 clear_llm_review_on_admin_decision    (trigger fn + trigger + data fix)
--   009000 preserve_llm_review_on_admin_decision (trigger fn slimmed down)
--   009100 event_enrichment_tags_and_scope       (list_events_needing_enrichment v3
--                                                 +tags, backfill_image_enrichment_in_scope)
--   009200 drop_admin_queue_tables_from_realtime  (ALTER PUBLICATION DROP TABLE x3)
--   009300 supabase_full_usage_hardening          (DROP EXTENSION pg_graphql; broad
--                                                 REVOKE ALL + targeted re-GRANT;
--                                                 default-privilege REVOKEs; RLS on
--                                                 private.cron_enabled/railway_cron_runs)
--   009400 enrichment_attempt_tracking            (events.last_enrichment_attempt_at,
--                                                 list/backfill v4 ORDER BY attempt,
--                                                 update_event_enrichment bump,
--                                                 mark_event_enrichment_attempt)
--
-- =====================================================================
-- !!! READ BEFORE RUNNING — THIS IS A FOUNDATIONAL, HIGH-RISK ROLLBACK !!!
-- =====================================================================
--
-- ORDERING HAZARD (must roll back HEAD-first). Migrations with a LARGER
-- timestamp than 004000 build directly on the enums, the
-- event_llm_review_queue / event_llm_review_traces tables, the events
-- llm_review_* columns, and the 9-arg admin_events_enriched shape created
-- here. Confirmed downstream dependents:
--   20260601006000_enrichment_images_and_rpc_cleanup.sql
--   20260601017000_event_status_enum_and_validate_checks.sql
--   20260601021000_admin_event_decisions.sql
--   20260601022000_source_auto_reject_and_stats.sql
--   20260601033000_community_event_submission.sql
--   20260610170000_admin_events_source_filter.sql
-- This down script ONLY undoes the 004000 deltas. Apply it AFTER every
-- larger-timestamp rollback has run; otherwise the DROP TYPE / DROP TABLE /
-- DROP COLUMN / DROP FUNCTION statements below will fail on a dependency
-- (or, worse, force you into CASCADE and silently delete downstream objects).
-- Do NOT add CASCADE to "fix" such a failure — stop and roll back HEAD first.
--
-- IRREVERSIBLE / STOP ITEMS — these source blocks are NOT undone here. See
-- the "STOP" section at the bottom. They are global Supabase-surface and
-- grant-matrix mutations whose exact prior state cannot be faithfully
-- reconstructed from the migration text without risking a security
-- regression (over-granting) or a divergent GraphQL surface:
--   * 009300 DROP EXTENSION pg_graphql
--   * 009300 REVOKE ALL ON ALL TABLES/SEQUENCES + ALTER DEFAULT PRIVILEGES
--             REVOKE (the baseline had blanket GRANT ALL ON TABLES TO
--             anon/authenticated; reversing to that is a security downgrade)
--   * 009300 ENABLE ROW LEVEL SECURITY on private.cron_enabled /
--             private.railway_cron_runs
--   * 009200 ALTER PUBLICATION supabase_realtime DROP TABLE (x3)
-- A best-effort, OPTIONAL restore for the publication + RLS-disable is
-- provided COMMENTED OUT at the bottom. The pg_graphql + grant-matrix reset
-- is intentionally left manual.
--
-- PRIOR-DEFINITION SOURCES for the REPLACED functions restored below:
--   * private.bulk_import_scrape_events(uuid,uuid,jsonb)
--       20260601000000_schema_baseline.sql lines 15-168
--   * private/public.admin_update_source(uuid,jsonb)
--       20260601003000_maintenance_and_admin_queues.sql lines 1098-1193
--   * private/public.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,int)
--       20260601003000_maintenance_and_admin_queues.sql lines 259-462
--       (most-recent prior; supersedes the identical-shape 002000 lines 511-664)
--   * private/public.list_events_needing_enrichment(int)  [pre-tags shape]
--       20260601002000_event_ingestion_admin_foundation.sql lines 714-790
--   * private/public.update_event_enrichment(uuid,numeric,numeric,jsonb)
--       20260601002000_event_ingestion_admin_foundation.sql lines 792-843
--
-- INTRODUCED (no earlier definition; inverse is DROP): the enums, the two
-- tables + summary view, the events/event_sources columns + constraints +
-- indexes, the trigger + clear_llm_review_on_status_change, and every queue/
-- admin RPC named in the DROP section below. NOTE: the baseline's tail GRANT
-- block (~line 6086+) was snapshotted AFTER 004000 ran, so it contains
-- GRANT ALL ... ON FUNCTION admin_bulk_set_auto_approve / admin_bulk_set_*
-- lines that reference functions this migration introduces. Dropping those
-- functions also drops their grants — the dangling baseline GRANT lines are
-- harmless (they only ran once, at baseline apply).

BEGIN;

-- check_function_bodies off: we recreate old function bodies that reference
-- columns/objects being torn down in this same transaction.
SET LOCAL check_function_bodies = off;

-- ===========================================================================
-- 1. Drop INTRODUCED RPCs (reverse of creation). public wrappers first, then
--    private implementations. Grants drop with the functions.
-- ===========================================================================

-- 009400 enrichment attempt tracking RPCs
DROP FUNCTION IF EXISTS public.mark_event_enrichment_attempt(uuid);
DROP FUNCTION IF EXISTS private.mark_event_enrichment_attempt(uuid);

-- 009100 backfill_image_enrichment_in_scope (introduced here; v2 ORDER BY in 009400)
DROP FUNCTION IF EXISTS public.backfill_image_enrichment_in_scope(int);
DROP FUNCTION IF EXISTS private.backfill_image_enrichment_in_scope(int);

-- 008500 apply_event_llm_review_decision (20-arg)
DROP FUNCTION IF EXISTS public.apply_event_llm_review_decision(
  bigint, uuid, uuid, uuid, text, text, text,
  public.llm_event_review_status, public.llm_event_review_decision, public.llm_event_review_decision,
  numeric, text, text[], text, text, jsonb, text, text, jsonb, integer
);
DROP FUNCTION IF EXISTS private.apply_event_llm_review_decision(
  bigint, uuid, uuid, uuid, text, text, text,
  public.llm_event_review_status, public.llm_event_review_decision, public.llm_event_review_decision,
  numeric, text, text[], text, text, jsonb, text, text, jsonb, integer
);

-- 008500 admin processing-mode + status RPCs
DROP FUNCTION IF EXISTS public.admin_update_event_status(uuid, text, text);
DROP FUNCTION IF EXISTS private.admin_update_event_status(uuid, text, text);
DROP FUNCTION IF EXISTS public.admin_set_event_source_processing_mode(uuid, public.event_processing_mode);
DROP FUNCTION IF EXISTS private.admin_set_event_source_processing_mode(uuid, public.event_processing_mode);
DROP FUNCTION IF EXISTS public.admin_bulk_set_auto_approve(boolean);
DROP FUNCTION IF EXISTS private.admin_bulk_set_auto_approve(boolean);
DROP FUNCTION IF EXISTS public.admin_bulk_set_processing_mode(public.event_processing_mode);
DROP FUNCTION IF EXISTS private.admin_bulk_set_processing_mode(public.event_processing_mode);

-- 008500 queue helper RPCs + cron invoker
DROP FUNCTION IF EXISTS public.invoke_process_event_review_queue();
DROP FUNCTION IF EXISTS public.reap_stuck_event_llm_review_rows();
DROP FUNCTION IF EXISTS private.reap_stuck_event_llm_review_rows();
DROP FUNCTION IF EXISTS public.release_unstarted_event_llm_review_rows(bigint[]);
DROP FUNCTION IF EXISTS private.release_unstarted_event_llm_review_rows(bigint[]);
DROP FUNCTION IF EXISTS public.mark_event_llm_review_queue_row_started(bigint);
DROP FUNCTION IF EXISTS private.mark_event_llm_review_queue_row_started(bigint);
DROP FUNCTION IF EXISTS public.claim_event_llm_review_queue_batch(integer);
DROP FUNCTION IF EXISTS private.claim_event_llm_review_queue_batch(integer);

-- ===========================================================================
-- 2. Restore REPLACED admin_events_enriched to the prior 7-arg shape.
--    The 9-arg shape (with p_llm_review_status / p_llm_review_decision and the
--    llm_* projection columns) is dropped; PG cannot CREATE OR REPLACE across a
--    RETURNS TABLE shape change, so drop the 9-arg overloads explicitly first.
--    Prior body: 20260601003000 lines 259-462.
-- ===========================================================================
DROP FUNCTION IF EXISTS public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision);
DROP FUNCTION IF EXISTS private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision);

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

-- ===========================================================================
-- 3. Restore REPLACED list_events_needing_enrichment to the pre-tags shape.
--    004000 changed the RETURNS TABLE shape (added `tags text[]`), so drop the
--    tags-shaped overloads first. Prior body: 20260601002000 lines 714-790.
-- ===========================================================================
DROP FUNCTION IF EXISTS public.list_events_needing_enrichment(int);
DROP FUNCTION IF EXISTS private.list_events_needing_enrichment(int);

CREATE OR REPLACE FUNCTION private.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    e.id,
    e.title,
    e.description,
    e.venue_name,
    e.address,
    e.city_id,
    e.source_id,
    e.source_url,
    (e.latitude IS NULL OR e.longitude IS NULL)
       AND NOT 'latitude'  = ANY(e.admin_locked_fields)
       AND NOT 'longitude' = ANY(e.admin_locked_fields)
       AS needs_coords,
    (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
       AND NOT 'images' = ANY(e.admin_locked_fields)
       AS needs_images,
    e.admin_locked_fields
  FROM public.events e
  WHERE (
    (e.latitude IS NULL OR e.longitude IS NULL)
       AND NOT 'latitude'  = ANY(e.admin_locked_fields)
       AND NOT 'longitude' = ANY(e.admin_locked_fields)
  )
  OR (
    (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
       AND NOT 'images' = ANY(e.admin_locked_fields)
  )
  ORDER BY e.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) TO service_role;

CREATE OR REPLACE FUNCTION public.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_events_needing_enrichment(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) TO service_role;

-- ===========================================================================
-- 4. Restore REPLACED update_event_enrichment (drop last_enrichment_attempt_at
--    bump). Same RETURNS void/signature, so CREATE OR REPLACE is sufficient.
--    Prior body: 20260601002000 lines 792-843.
-- ===========================================================================
CREATE OR REPLACE FUNCTION private.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.events e SET
    latitude = CASE
      WHEN 'latitude' = ANY(e.admin_locked_fields) THEN e.latitude
      WHEN p_latitude IS NULL THEN e.latitude
      ELSE p_latitude
    END,
    longitude = CASE
      WHEN 'longitude' = ANY(e.admin_locked_fields) THEN e.longitude
      WHEN p_longitude IS NULL THEN e.longitude
      ELSE p_longitude
    END,
    images = CASE
      WHEN 'images' = ANY(e.admin_locked_fields) THEN e.images
      WHEN p_images IS NULL OR jsonb_array_length(p_images) = 0 THEN e.images
      ELSE p_images
    END,
    updated_at = now()
  WHERE e.id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.update_event_enrichment(p_event_id, p_latitude, p_longitude, p_images);
$$;

REVOKE EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

-- ===========================================================================
-- 5. Restore REPLACED admin_update_source (drop processing_mode CASE branch).
--    Same signature, CREATE OR REPLACE sufficient.
--    Prior body: 20260601003000 lines 1098-1193. Grants were last set in 003000
--    and are unchanged by 004000, so they are left intact.
-- ===========================================================================
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

-- ===========================================================================
-- 6. Restore REPLACED bulk_import_scrape_events to the pre-llm-review baseline
--    body (no processing_mode, no llm_review_* columns, no review-queue enqueue).
--    Same signature, CREATE OR REPLACE sufficient.
--    Prior body: 20260601000000_schema_baseline.sql lines 15-168.
-- ===========================================================================
CREATE OR REPLACE FUNCTION private.bulk_import_scrape_events(p_run_id uuid, p_source_id uuid, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_auto_approve boolean;
  v_status       text;
  v_imported     int := 0;
  v_updated      int := 0;
  v_enqueued     int := 0;
BEGIN
  SELECT auto_approve INTO v_auto_approve
  FROM public.event_sources WHERE id = p_source_id;

  IF v_auto_approve IS NULL THEN
    RAISE EXCEPTION 'source not found: %', p_source_id USING ERRCODE = 'P0002';
  END IF;

  v_status := CASE WHEN v_auto_approve THEN 'published' ELSE 'draft' END;

  WITH inputs AS (
    SELECT
      (idx - 1)::int AS ord,
      (elem->>'title')::text                         AS title,
      (elem->>'description')::text                   AS description,
      (elem->>'start_datetime')::timestamptz         AS start_datetime,
      NULLIF(elem->>'end_datetime', '')::timestamptz AS end_datetime,
      (elem->>'timezone')::text                      AS timezone,
      (elem->>'venue_name')::text                    AS venue_name,
      (elem->>'address')::text                       AS address,
      NULLIF(elem->>'city_id', '')::uuid             AS city_id,
      NULLIF(elem->>'source_url', '')::text          AS source_url,
      (elem->>'source_name')::text                   AS source_name,
      COALESCE(elem->'images', '[]'::jsonb)          AS images,
      NULLIF(elem->>'price', '')::numeric            AS price,
      COALESCE((elem->>'is_free')::boolean, false)   AS is_free,
      NULLIF(elem->>'is_outdoor', '')::boolean       AS is_outdoor,
      NULLIF(elem->>'latitude', '')::numeric         AS latitude,
      NULLIF(elem->>'longitude', '')::numeric        AS longitude
    FROM jsonb_array_elements(p_events) WITH ORDINALITY AS j(elem, idx)
  ),
  classified AS (
    SELECT
      i.*,
      su.id AS source_url_match,
      CASE WHEN su.id IS NOT NULL THEN 'update' ELSE 'insert' END AS decision
    FROM inputs i
    LEFT JOIN LATERAL (
      SELECT e.id FROM public.events e
      WHERE e.source_id = p_source_id
        AND e.source_url IS NOT NULL
        AND e.source_url = i.source_url
      LIMIT 1
    ) su ON i.source_url IS NOT NULL
  ),
  inserted AS (
    INSERT INTO public.events (
      title, description, start_datetime, end_datetime, timezone,
      venue_name, address, city_id, latitude, longitude,
      price, is_free, is_outdoor,
      source_url, source_name, source_id,
      images, status
    )
    SELECT
      c.title, c.description, c.start_datetime, c.end_datetime, c.timezone,
      c.venue_name, c.address, c.city_id, c.latitude, c.longitude,
      c.price, c.is_free, c.is_outdoor,
      c.source_url, c.source_name, p_source_id,
      c.images, v_status
    FROM classified c
    WHERE c.decision = 'insert'
    ON CONFLICT (source_id, source_url)
      WHERE source_url IS NOT NULL
      DO NOTHING
    RETURNING id, source_url
  ),
  update_targets AS (
    SELECT c.*, e.id AS event_id, e.admin_locked_fields
    FROM classified c
    JOIN public.events e
      ON e.source_id = p_source_id
     AND e.source_url IS NOT NULL
     AND e.source_url = c.source_url
    WHERE c.decision = 'update'
       OR (
         c.decision = 'insert'
         AND c.source_url IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM inserted i WHERE i.source_url = c.source_url)
       )
  ),
  updated AS (
    UPDATE public.events e SET
      title          = CASE WHEN 'title'          = ANY(e.admin_locked_fields) THEN e.title          ELSE t.title          END,
      description    = CASE WHEN 'description'    = ANY(e.admin_locked_fields) THEN e.description    ELSE t.description    END,
      start_datetime = CASE WHEN 'start_datetime' = ANY(e.admin_locked_fields) THEN e.start_datetime ELSE t.start_datetime END,
      end_datetime   = CASE WHEN 'end_datetime'   = ANY(e.admin_locked_fields) THEN e.end_datetime   ELSE t.end_datetime   END,
      timezone       = CASE WHEN 'timezone'       = ANY(e.admin_locked_fields) THEN e.timezone       ELSE t.timezone       END,
      venue_name     = CASE WHEN 'venue_name'     = ANY(e.admin_locked_fields) THEN e.venue_name     ELSE t.venue_name     END,
      address        = CASE WHEN 'address'        = ANY(e.admin_locked_fields) THEN e.address        ELSE t.address        END,
      city_id        = CASE WHEN 'city_id'        = ANY(e.admin_locked_fields) THEN e.city_id        ELSE t.city_id        END,
      source_url     = CASE WHEN 'source_url'     = ANY(e.admin_locked_fields) THEN e.source_url     ELSE t.source_url     END,
      source_name    = CASE WHEN 'source_name'    = ANY(e.admin_locked_fields) THEN e.source_name    ELSE t.source_name    END,
      source_id      = CASE WHEN 'source_id'      = ANY(e.admin_locked_fields) THEN e.source_id      ELSE p_source_id      END,
      images         = CASE WHEN 'images'         = ANY(e.admin_locked_fields) THEN e.images         ELSE t.images         END,
      price          = CASE WHEN 'price'          = ANY(e.admin_locked_fields) THEN e.price          ELSE t.price          END,
      is_free        = CASE WHEN 'is_free'        = ANY(e.admin_locked_fields) THEN e.is_free        ELSE t.is_free        END,
      is_outdoor     = CASE WHEN 'is_outdoor'     = ANY(e.admin_locked_fields) THEN e.is_outdoor     ELSE t.is_outdoor     END,
      updated_at     = now()
    FROM update_targets t
    WHERE e.id = t.event_id
    RETURNING e.id
  ),
  all_imported AS (
    SELECT id FROM inserted
    UNION ALL
    SELECT event_id AS id FROM update_targets
  ),
  enqueued AS (
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    SELECT id, p_run_id, 'import' FROM all_imported
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING
    RETURNING id
  )
  SELECT
    (SELECT COUNT(*) FROM inserted),
    (SELECT COUNT(*) FROM updated),
    (SELECT COUNT(*) FROM enqueued)
  INTO v_imported, v_updated, v_enqueued;

  RETURN jsonb_build_object(
    'imported', v_imported,
    'updated',  v_updated,
    'skipped',  0,
    'enqueued', v_enqueued
  );
END;
$function$;

-- ===========================================================================
-- 7. Drop INTRODUCED trigger + trigger function (008900 / slimmed in 009000).
-- ===========================================================================
DROP TRIGGER IF EXISTS trg_clear_llm_review_on_status_change ON public.events;
DROP FUNCTION IF EXISTS private.clear_llm_review_on_status_change();

-- ===========================================================================
-- 8. Drop INTRODUCED summary view + queue/traces tables.
--    RLS policies and per-table indexes drop with the tables.
-- ===========================================================================
DROP VIEW IF EXISTS public.event_llm_review_queue_summary;
DROP TABLE IF EXISTS public.event_llm_review_traces;
DROP TABLE IF EXISTS public.event_llm_review_queue;

-- ===========================================================================
-- 9. Drop INTRODUCED events columns + their constraints/indexes.
--    (Indexes and CHECK constraints drop with the columns, but they are listed
--    explicitly first for clarity / partial-rerun safety.)
-- ===========================================================================
DROP INDEX IF EXISTS public.events_llm_review_decision_created_idx;
DROP INDEX IF EXISTS public.events_llm_review_status_created_idx;
DROP INDEX IF EXISTS public.events_enrichment_attempt_idx;

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_llm_review_reason_required_when_decided;
ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_llm_review_confidence_range;

ALTER TABLE public.events
  DROP COLUMN IF EXISTS last_enrichment_attempt_at,
  DROP COLUMN IF EXISTS llm_review_error,
  DROP COLUMN IF EXISTS llm_reviewed_at,
  DROP COLUMN IF EXISTS llm_review_prompt_version,
  DROP COLUMN IF EXISTS llm_review_model,
  DROP COLUMN IF EXISTS llm_review_provider,
  DROP COLUMN IF EXISTS llm_review_flags,
  DROP COLUMN IF EXISTS llm_review_reason,
  DROP COLUMN IF EXISTS llm_review_confidence,
  DROP COLUMN IF EXISTS llm_review_decision,
  DROP COLUMN IF EXISTS llm_review_status;

-- ===========================================================================
-- 10. Drop INTRODUCED event_sources.processing_mode column + its index.
--     The accompanying UPDATE backfill and the SET DEFAULT/SET NOT NULL are
--     undone implicitly by dropping the column.
-- ===========================================================================
DROP INDEX IF EXISTS public.event_sources_processing_mode_idx;
ALTER TABLE public.event_sources
  DROP COLUMN IF EXISTS processing_mode;

-- ===========================================================================
-- 11. Drop INTRODUCED enums (now unreferenced after columns + functions gone).
--     Order does not matter among them; they have no inter-dependencies.
-- ===========================================================================
DROP TYPE IF EXISTS public.llm_event_review_queue_status;
DROP TYPE IF EXISTS public.llm_event_review_status;
DROP TYPE IF EXISTS public.llm_event_review_decision;
DROP TYPE IF EXISTS public.event_processing_mode;

COMMIT;

-- ===========================================================================
-- STOP / IRREVERSIBLE — NOT undone above. Review and act manually if needed.
-- ===========================================================================
--
-- (a) 009300 DROP EXTENSION pg_graphql
--     The baseline created pg_graphql (schema "graphql"). Re-creating it is
--     possible (CREATE EXTENSION pg_graphql WITH SCHEMA graphql;) but the
--     regenerated GraphQL surface/resolvers depend on the table-grant matrix,
--     which 009300 also changed (see (b)). Restoring an identical GraphQL
--     surface is not guaranteed from migration text alone. Left manual.
--
-- (b) 009300 grant-matrix reset. The migration ran:
--       REVOKE ALL ON ALL TABLES   IN SCHEMA public FROM anon, authenticated;
--       REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
--       ALTER DEFAULT PRIVILEGES ... REVOKE ALL ON TABLES/SEQUENCES FROM ...;
--     then re-granted a narrow allowlist. The PRIOR state (baseline) was
--     blanket "GRANT ALL ON TABLES/SEQUENCES TO anon, authenticated" plus
--     ALTER DEFAULT PRIVILEGES ... GRANT ALL ... TO anon/authenticated, and
--     hundreds of per-object GRANT ALL lines. Faithfully reversing means
--     RE-GRANTING ALL to anon/authenticated, which is a SECURITY REGRESSION
--     (it re-opens write access broadly and re-exposes every object to
--     GraphQL). DO NOT auto-restore. If a true rollback to baseline grants is
--     required, replay the baseline GRANT section (20260601000000 ~line
--     6086-6900) deliberately and re-audit. Left manual.
--
-- (c) 009300 ENABLE ROW LEVEL SECURITY on private.cron_enabled /
--     private.railway_cron_runs. To revert: see commented block below.
--     Disabling RLS is also a security loosening — confirm before running.
--
-- (d) 009200 ALTER PUBLICATION supabase_realtime DROP TABLE
--       public.event_tag_queue, public.source_scrape_queue, public.source_runs.
--     Re-adding them re-enables realtime WAL churn the migration removed for a
--     measured cost reason. To revert: see commented block below. Note these
--     tables must still exist (they predate this migration) for ADD to work.
--
-- OPTIONAL best-effort restore for (c) and (d) — review before uncommenting:
--
-- BEGIN;
--   -- (d) realtime publication membership
--   ALTER PUBLICATION supabase_realtime ADD TABLE public.event_tag_queue;
--   ALTER PUBLICATION supabase_realtime ADD TABLE public.source_scrape_queue;
--   ALTER PUBLICATION supabase_realtime ADD TABLE public.source_runs;
--   -- (c) RLS toggles
--   ALTER TABLE private.cron_enabled       DISABLE ROW LEVEL SECURITY;
--   ALTER TABLE private.railway_cron_runs  DISABLE ROW LEVEL SECURITY;
-- COMMIT;
