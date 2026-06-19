-- Rollback for 20260601006000_enrichment_images_and_rpc_cleanup.sql
-- ============================================================================
-- WHAT THIS MIGRATION IS
-- ----------------------------------------------------------------------------
-- 20260601006000 is a SQUASHED migration: it concatenates 14 sub-migrations
-- (sub-source timestamps 009600..009902, see the `-- Source:` banners in the
-- UP file). The repo's migrations are bucketed squashes; the chronological
-- chain across buckets is:
--     baseline 20260601000000      -> sources (the SQL dump itself)
--     20260601001000              -> sources 006xxx (search_events v1 lives here)
--     20260601002000              -> sources 007000..007500 (events_enriched_v2,
--                                    search_events_v2 introduced here)
--     20260601003000              -> sources 007600..008400
--     20260601004000              -> sources 008500..009400 (admin_events_enriched
--                                    9-arg, list_events_needing_enrichment last
--                                    pre-006000 def)
--     20260601005000              -> sources 009500..009504 (ai_feature_config,
--                                    upsert_ai_feature_config last pre-006000 def)
--     20260601006000 (THIS)       -> sources 009600..009902
--
-- Therefore "prior state" for this rollback = the cumulative end-state at the
-- close of 20260601005000 (sub-source 009504). Every prior body cited below
-- is the LAST definition of that object with a sub-source timestamp <= 009504.
--
-- PRIOR-DEFINITION SOURCES (file:line)
-- ----------------------------------------------------------------------------
--   events_enriched (v1, 8-param offset):  20260601000000_schema_baseline.sql:3592-3640
--   search_events   (v1, 12-param offset): 20260601001000_reference_security_and_cron.sql:335-415
--   events_enriched_v2 (33-col, cap 200):  20260601002000_event_ingestion_admin_foundation.sql:276-386
--   search_events_v2 (14-param):           20260601002000_event_ingestion_admin_foundation.sql:394-497
--   admin_events_enriched (9-arg):         20260601004000_llm_review_and_enrichment.sql:719-946 + grants 1421-1429
--   list_events_needing_enrichment:        20260601004000_llm_review_and_enrichment.sql:2178-2282
--   upsert_ai_feature_config (2-feature):  20260601005000_ai_models_and_cron_drilldown.sql:290-346
--   5 review-queue/traces partial indexes: 20260601000000_schema_baseline.sql:533-577
--   ai_feature_config_feature_check:       inline 2-value check from
--                                          20260601005000_ai_models_and_cron_drilldown.sql:251-253
--
-- ORDERING HAZARDS
-- ----------------------------------------------------------------------------
-- * This rollback assumes every later migration (007000..) has ALREADY been
--   rolled back first (rollbacks run newest-first). In particular it assumes
--   the radius/decision_reason/enum work in 017000/018000/019000/021000/028000/
--   032000 is gone, so the function shapes restored here do not collide.
-- * search_events: after rollback BOTH public.search_events(12-param v1) and
--   public.search_events_v2(14-param) coexist again — this is exactly the
--   end-of-005000 state, NOT a new ambiguity. The 14-param public.search_events
--   that 009902 created is dropped.
-- * events_enriched: after rollback BOTH public.events_enriched(8-param v1) and
--   public.events_enriched_v2(9-param) coexist again (end-of-005000 state). The
--   9-param public.events_enriched that 009902 created is dropped.
-- * check_function_bodies is set off because several restored bodies reference
--   objects (event_image_attributions) that this same script drops, and the
--   v1/v2 overloads recreated for search/enriched are validated lazily.
--
-- STOP / IRREVERSIBILITY FLAGS
-- ----------------------------------------------------------------------------
-- * DATA LOSS (accepted, unavoidable): dropping public.event_image_attributions
--   destroys all Unsplash attribution rows. There is no prior table to restore
--   to (the table is introduced by this migration); the rows cannot be
--   reconstructed. Unsplash API ToS requires download tracking — re-running the
--   forward migration will re-collect attributions for newly enriched events
--   only. If preserving existing attribution rows matters, snapshot the table
--   BEFORE running this rollback.
-- * GUARD TEST: 20260601006000 is currently in LEGACY_ALLOWLIST in
--   tests/guards/migration-rollbacks.test.mjs. Adding this file makes the
--   "legacy allowlist only contains migrations that still lack rollbacks" test
--   FAIL until "20260601006000" is removed from that allowlist. That edit is
--   intentionally NOT made here (out of scope for this file); the caller must
--   remove the allowlist entry in the same change.
-- ============================================================================

BEGIN;

SET LOCAL check_function_bodies = off;

-- ============================================================================
-- Reverse of source 009902 (rename _v2 RPCs to canonical) + 009900 (drop v1
-- search_events). Done first because it is the newest sub-source.
-- ============================================================================

-- 009902 created public.search_events(14-param) from the search_events_v2 body
-- and dropped search_events_v2. Drop that canonical 14-param overload.
DROP FUNCTION IF EXISTS public.search_events(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
);

-- Restore search_events_v2 (14-param) verbatim from
-- 20260601002000_event_ingestion_admin_foundation.sql:394-497.
CREATE OR REPLACE FUNCTION public.search_events_v2(
  p_city_id               uuid DEFAULT NULL::uuid,
  p_date_from             timestamptz DEFAULT NULL::timestamptz,
  p_date_to               timestamptz DEFAULT NULL::timestamptz,
  p_age_min               integer DEFAULT NULL::integer,
  p_age_max               integer DEFAULT NULL::integer,
  p_is_free               boolean DEFAULT NULL::boolean,
  p_is_featured           boolean DEFAULT NULL::boolean,
  p_tag_slugs             text[] DEFAULT NULL::text[],
  p_keyword               text DEFAULT NULL::text,
  p_status                text DEFAULT 'published'::text,
  p_limit                 integer DEFAULT 100,
  p_offset                integer DEFAULT 0,
  p_after_start_datetime  timestamptz DEFAULT NULL::timestamptz,
  p_after_id              uuid DEFAULT NULL::uuid
)
RETURNS SETOF public.events
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
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
        ELSE replace(replace(replace(btrim(p_keyword), '\', '\\'), '%', '\%'), '_', '\_')
      END AS escaped_kw
  )
  SELECT e.*
  FROM public.events e
  CROSS JOIN search_input si
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
    AND (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (p_is_free IS NULL OR e.is_free = p_is_free)
    AND (p_is_featured IS NULL OR e.is_featured = p_is_featured)
    AND (p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min)
    AND (p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max)
    AND (
      si.kw IS NULL
      OR (
        si.tsq IS NOT NULL
        AND numnode(si.tsq) > 0
        AND e.search_vector @@ si.tsq
      )
      OR (
        si.escaped_kw IS NOT NULL
        AND (numnode(si.tsq) = 0 OR length(si.kw) < 3)
        AND (
          e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
          OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
        )
      )
    )
    AND (
      p_tag_slugs IS NULL
      OR array_length(p_tag_slugs, 1) IS NULL
      OR (
        SELECT COUNT(DISTINCT t.slug)
        FROM public.event_tags et
        JOIN public.tags t ON t.id = et.tag_id
        WHERE et.event_id = e.id AND t.slug = ANY(p_tag_slugs)
      ) = array_length(p_tag_slugs, 1)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY
    CASE
      WHEN si.tsq IS NULL OR numnode(si.tsq) = 0 THEN NULL::real
      ELSE ts_rank_cd(e.search_vector, si.tsq)
    END DESC NULLS LAST,
    e.start_datetime ASC,
    e.id ASC
  LIMIT LEAST(GREATEST(p_limit, 0), 500)
  OFFSET GREATEST(p_offset, 0);
$$;

REVOKE ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) TO anon;
GRANT ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) TO authenticated;
GRANT ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) TO service_role;

-- 009902 dropped the v1 8-param events_enriched and created a 9-param
-- public.events_enriched (v2 body, cap 500). Drop that canonical 9-param.
DROP FUNCTION IF EXISTS public.events_enriched(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
);

-- ============================================================================
-- Reverse of source 009900: restore search_events v1 (12-param, offset-based)
-- verbatim from 20260601001000_reference_security_and_cron.sql:335-415.
-- 009900 issued `REVOKE ALL ... FROM anon, authenticated` then DROP; restore
-- both the function and its original baseline grants (anon/authenticated/
-- service_role; these predate the 007200 default-privilege revoke and had
-- explicit GRANT ALL in baseline).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.search_events(
  p_city_id uuid DEFAULT NULL::uuid,
  p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_age_min integer DEFAULT NULL::integer,
  p_age_max integer DEFAULT NULL::integer,
  p_is_free boolean DEFAULT NULL::boolean,
  p_is_featured boolean DEFAULT NULL::boolean,
  p_tag_slugs text[] DEFAULT NULL::text[],
  p_keyword text DEFAULT NULL::text,
  p_status text DEFAULT 'published'::text,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS SETOF public.events
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
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
        ELSE replace(replace(replace(btrim(p_keyword), '\', '\\'), '%', '\%'), '_', '\_')
      END AS escaped_kw
  )
  SELECT e.*
  FROM public.events e
  CROSS JOIN search_input si
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
    AND (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (p_is_free IS NULL OR e.is_free = p_is_free)
    AND (p_is_featured IS NULL OR e.is_featured = p_is_featured)
    AND (p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min)
    AND (p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max)
    AND (
      si.kw IS NULL
      OR (
        si.tsq IS NOT NULL
        AND numnode(si.tsq) > 0
        AND e.search_vector @@ si.tsq
      )
      OR (
        si.escaped_kw IS NOT NULL
        AND (numnode(si.tsq) = 0 OR length(si.kw) < 3)
        AND (
          e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
          OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
        )
      )
    )
    AND (
      p_tag_slugs IS NULL
      OR array_length(p_tag_slugs, 1) IS NULL
      OR (
        SELECT COUNT(DISTINCT t.slug)
        FROM public.event_tags et
        JOIN public.tags t ON t.id = et.tag_id
        WHERE et.event_id = e.id AND t.slug = ANY(p_tag_slugs)
      ) = array_length(p_tag_slugs, 1)
    )
  ORDER BY
    CASE
      WHEN si.tsq IS NULL OR numnode(si.tsq) = 0 THEN NULL::real
      ELSE ts_rank_cd(e.search_vector, si.tsq)
    END DESC NULLS LAST,
    e.start_datetime ASC,
    e.id ASC
  LIMIT LEAST(GREATEST(p_limit, 0), 500)
  OFFSET GREATEST(p_offset, 0);
$$;

GRANT ALL ON FUNCTION public.search_events(
  uuid, timestamp with time zone, timestamp with time zone, integer, integer,
  boolean, boolean, text[], text, text, integer, integer
) TO anon, authenticated, service_role;

-- ============================================================================
-- Reverse of source 009709: drop the public.pg_timezone_names compatibility
-- view (INTRODUCED by 009709 — no prior definition exists in baseline or any
-- earlier bucket; baseline has a different view, public.timezone_names, which
-- is intentionally left untouched).
-- ============================================================================
DROP VIEW IF EXISTS public.pg_timezone_names;

-- ============================================================================
-- Reverse of source 009708: the 5 review-queue/traces FK indexes were dropped
-- (partial form) and recreated as plain btree. Drop the plain form and restore
-- the partial-index form from 20260601000000_schema_baseline.sql:533-577.
-- ============================================================================
DROP INDEX IF EXISTS public.event_llm_review_queue_source_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_queue_source_run_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_queue_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_source_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_source_run_id_idx;

CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_id_idx
  ON public.event_llm_review_queue USING btree (source_id)
  WHERE source_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_run_id_idx
  ON public.event_llm_review_queue USING btree (source_run_id)
  WHERE source_run_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS event_llm_review_traces_queue_id_idx
  ON public.event_llm_review_traces USING btree (queue_id)
  WHERE queue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_id_idx
  ON public.event_llm_review_traces USING btree (source_id)
  WHERE source_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_run_id_idx
  ON public.event_llm_review_traces USING btree (source_run_id)
  WHERE source_run_id IS NOT NULL;

-- ============================================================================
-- Reverse of source 009704 + 009706 + the events_enriched_v2 image-attribution
-- additions (009704/009707): drop the entire event_image_attributions feature
-- and the functions that read/write it, then restore events_enriched_v2 to its
-- pre-006000 (002000) shape.
--
-- NOTE: public.events_enriched_v2 must be dropped/recreated BEFORE the
-- private.public_event_image_attributions function and the
-- event_image_attributions table, because the post-006000 v2 body references
-- them. We recreate the 002000 v2 body (which does NOT reference attributions)
-- here, breaking that dependency, then drop the attribution objects.
-- ============================================================================

-- Restore events_enriched_v2 to the 002000 shape (33 cols, no is_outdoor /
-- parent_tips / image_attributions; LIMIT cap 200; STABLE, no SECURITY DEFINER)
-- verbatim from 20260601002000_event_ingestion_admin_foundation.sql:276-386.
-- First drop the current (post-006000) shape so the RETURNS TABLE change applies.
DROP FUNCTION IF EXISTS public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
);

CREATE OR REPLACE FUNCTION public.events_enriched_v2(
  p_city_id               uuid DEFAULT NULL::uuid,
  p_status                text DEFAULT 'published'::text,
  p_user_id               uuid DEFAULT NULL::uuid,
  p_event_ids             uuid[] DEFAULT NULL::uuid[],
  p_date_from             timestamptz DEFAULT NULL::timestamptz,
  p_date_to               timestamptz DEFAULT NULL::timestamptz,
  p_after_start_datetime  timestamptz DEFAULT NULL::timestamptz,
  p_after_id              uuid DEFAULT NULL::uuid,
  p_limit                 int DEFAULT 24
)
RETURNS TABLE (
  id               uuid,
  title            text,
  description      text,
  start_datetime   timestamptz,
  end_datetime     timestamptz,
  timezone         text,
  venue_name       text,
  address          text,
  city_id          uuid,
  latitude         numeric,
  longitude        numeric,
  age_min          integer,
  age_max          integer,
  price            numeric,
  is_free          boolean,
  source_url       text,
  source_name      text,
  source_id        uuid,
  images           jsonb,
  status           text,
  ai_confidence    numeric,
  ai_tag_provider  text,
  recurrence_info  jsonb,
  is_featured      boolean,
  view_count       integer,
  search_vector    tsvector,
  created_at       timestamptz,
  updated_at       timestamptz,
  avg_rating       numeric,
  rating_count     integer,
  tags             jsonb,
  is_favorited     boolean,
  is_in_calendar   boolean
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured, e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    (p_user_id IS NOT NULL AND f.event_id IS NOT NULL)  AS is_favorited,
    (p_user_id IS NOT NULL AND c.event_id IS NOT NULL)  AS is_in_calendar
  FROM public.events e
  LEFT JOIN LATERAL (
    SELECT ROUND(AVG(r.score)::numeric, 1) AS avg_score,
           COUNT(*)::int AS rating_count
    FROM public.ratings r
    WHERE r.event_id = e.id
  ) rs ON TRUE
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object('id', t.id, 'name', t.name, 'slug', t.slug, 'color', t.color)
             ORDER BY t.name
           ) AS tags
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    WHERE et.event_id = e.id
  ) ts ON TRUE
  LEFT JOIN public.favorites f
    ON p_user_id IS NOT NULL AND f.event_id = e.id AND f.user_id = p_user_id
  LEFT JOIN public.user_calendar_events c
    ON p_user_id IS NOT NULL AND c.event_id = e.id AND c.user_id = p_user_id
  WHERE
    (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (
      p_event_ids IS NOT NULL AND e.id = ANY(p_event_ids)
      OR p_event_ids IS NULL
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY e.start_datetime ASC, e.id ASC
  LIMIT CASE WHEN p_event_ids IS NULL THEN LEAST(GREATEST(p_limit, 1), 200) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) FROM PUBLIC;
GRANT ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO anon;
GRANT ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO authenticated;
GRANT ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO service_role;

-- Drop the attribution-backfill RPC (source 009706, INTRODUCED → drop).
DROP FUNCTION IF EXISTS public.list_events_needing_attribution_backfill(int);
DROP FUNCTION IF EXISTS private.list_events_needing_attribution_backfill(int);

-- Drop all event_image_attributions read/write RPCs (source 009704,
-- all INTRODUCED → drop). Order: wrappers/readers first, then writers.
DROP FUNCTION IF EXISTS public.mark_unsplash_download_tracking_result(uuid, boolean, text);
DROP FUNCTION IF EXISTS private.mark_unsplash_download_tracking_result(uuid, boolean, text);
DROP FUNCTION IF EXISTS public.list_pending_unsplash_download_tracking(int);
DROP FUNCTION IF EXISTS private.list_pending_unsplash_download_tracking(int);
DROP FUNCTION IF EXISTS public.upsert_event_image_attribution_with_enrichment(
  uuid, numeric, numeric, jsonb, text, text, text, text, text, text, text, text
);
DROP FUNCTION IF EXISTS private.upsert_event_image_attribution_with_enrichment(
  uuid, numeric, numeric, jsonb, text, text, text, text, text, text, text, text
);
DROP FUNCTION IF EXISTS private.public_event_image_attributions(uuid);

-- Drop the touch trigger + its function (source 009704, INTRODUCED → drop).
DROP TRIGGER IF EXISTS event_image_attributions_touch_updated_at ON public.event_image_attributions;
DROP FUNCTION IF EXISTS private.touch_event_image_attributions_updated_at();

-- Drop the table itself (its policy + indexes go with it).
-- *** DATA LOSS: all Unsplash attribution rows are destroyed here. ***
DROP TABLE IF EXISTS public.event_image_attributions;

-- ============================================================================
-- Reverse of source 009703 (admin_events_enriched LLM-reviewed filter):
-- 009703 dropped the 9-arg overload and created a 10-arg overload that adds
-- p_llm_reviewed. Drop the 10-arg overload and restore the 9-arg overload
-- verbatim from 20260601004000_llm_review_and_enrichment.sql:719-946 with the
-- grants from 1421-1429.
-- ============================================================================
DROP FUNCTION IF EXISTS public.admin_events_enriched(
  text, uuid, boolean, text, timestamptz, uuid, int,
  public.llm_event_review_status, public.llm_event_review_decision, boolean
);
DROP FUNCTION IF EXISTS private.admin_events_enriched(
  text, uuid, boolean, text, timestamptz, uuid, int,
  public.llm_event_review_status, public.llm_event_review_decision, boolean
);

CREATE OR REPLACE FUNCTION private.admin_events_enriched(
  p_status               text                              DEFAULT NULL::text,
  p_city_id              uuid                              DEFAULT NULL::uuid,
  p_city_is_null         boolean                           DEFAULT NULL::boolean,
  p_keyword              text                              DEFAULT NULL::text,
  p_after_created_at     timestamptz                       DEFAULT NULL::timestamptz,
  p_after_id             uuid                              DEFAULT NULL::uuid,
  p_limit                int                               DEFAULT 50,
  p_llm_review_status    public.llm_event_review_status    DEFAULT NULL::public.llm_event_review_status,
  p_llm_review_decision  public.llm_event_review_decision  DEFAULT NULL::public.llm_event_review_decision
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
  llm_review_status     public.llm_event_review_status,
  llm_review_decision   public.llm_event_review_decision,
  llm_review_confidence numeric(4,3),
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamptz,
  llm_review_error      text,
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
      AND (p_llm_review_status IS NULL OR e.llm_review_status = p_llm_review_status)
      AND (p_llm_review_decision IS NULL OR e.llm_review_decision = p_llm_review_decision)
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
    SELECT b.*, c.total_count
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
    p.llm_review_status, p.llm_review_decision, p.llm_review_confidence, p.llm_review_reason,
    p.llm_review_flags, p.llm_review_provider, p.llm_review_model, p.llm_review_prompt_version,
    p.llm_reviewed_at, p.llm_review_error,
    p.total_count
  FROM page p;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_events_enriched(
  p_status               text                              DEFAULT NULL::text,
  p_city_id              uuid                              DEFAULT NULL::uuid,
  p_city_is_null         boolean                           DEFAULT NULL::boolean,
  p_keyword              text                              DEFAULT NULL::text,
  p_after_created_at     timestamptz                       DEFAULT NULL::timestamptz,
  p_after_id             uuid                              DEFAULT NULL::uuid,
  p_limit                int                               DEFAULT 50,
  p_llm_review_status    public.llm_event_review_status    DEFAULT NULL::public.llm_event_review_status,
  p_llm_review_decision  public.llm_event_review_decision  DEFAULT NULL::public.llm_event_review_decision
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
  llm_review_status     public.llm_event_review_status,
  llm_review_decision   public.llm_event_review_decision,
  llm_review_confidence numeric(4,3),
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamptz,
  llm_review_error      text,
  total_count           bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_events_enriched(
    p_status,
    p_city_id,
    p_city_is_null,
    p_keyword,
    p_after_created_at,
    p_after_id,
    p_limit,
    p_llm_review_status,
    p_llm_review_decision
  );
$$;

REVOKE EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision)
  TO authenticated;

-- ============================================================================
-- Reverse of source 009702 (parent tips). Drop everything INTRODUCED, restore
-- the two REPLACED objects (ai_feature_config_feature_check, upsert_ai_feature_config),
-- and delete the seeded 'parent-tips' config row.
-- events_enriched_v2 was also touched by 009702 but is already fully restored
-- above (to the 002000 shape), so no further action is needed for it here.
-- ============================================================================

-- Drop the parent-tips persist + claim RPCs (INTRODUCED → drop).
DROP FUNCTION IF EXISTS public.update_event_parent_tips(uuid, jsonb, text, text, text);
DROP FUNCTION IF EXISTS private.update_event_parent_tips(uuid, jsonb, text, text, text);
DROP FUNCTION IF EXISTS public.list_events_needing_parent_tips(int);
DROP FUNCTION IF EXISTS private.list_events_needing_parent_tips(int);

-- Restore upsert_ai_feature_config to the 2-feature ('tagging','event-review')
-- version verbatim from 20260601005000_ai_models_and_cron_drilldown.sql:290-346
-- (private SECURITY DEFINER impl + public SECURITY INVOKER wrapper + grants).
CREATE OR REPLACE FUNCTION private.upsert_ai_feature_config(
  p_feature  text,
  p_model_id text,
  p_enabled  bool
) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_feature NOT IN ('tagging', 'event-review') THEN
    RAISE EXCEPTION 'invalid feature: %', p_feature;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.approved_ai_models
    WHERE id = p_model_id AND is_enabled = true
  ) THEN
    RAISE EXCEPTION 'model % not found or disabled', p_model_id;
  END IF;

  INSERT INTO public.ai_feature_config (feature, model_id, enabled, updated_at, updated_by)
  VALUES (p_feature, p_model_id, p_enabled, now(), auth.uid())
  ON CONFLICT (feature) DO UPDATE SET
    model_id   = EXCLUDED.model_id,
    enabled    = EXCLUDED.enabled,
    updated_at = now(),
    updated_by = auth.uid();
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_ai_feature_config(
  p_feature  text,
  p_model_id text,
  p_enabled  bool DEFAULT true
) RETURNS void
  LANGUAGE sql
  SECURITY INVOKER
  SET search_path = ''
AS $$
  SELECT private.upsert_ai_feature_config(p_feature, p_model_id, p_enabled);
$$;

REVOKE EXECUTE ON FUNCTION public.upsert_ai_feature_config(text, text, bool)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_ai_feature_config(text, text, bool)
  TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  TO service_role;

-- Delete the seeded 'parent-tips' ai_feature_config row (009702 INSERT ... ON
-- CONFLICT DO NOTHING). Must run BEFORE re-adding the 2-value CHECK below, or
-- the constraint add would fail on the existing 'parent-tips' row.
DELETE FROM public.ai_feature_config WHERE feature = 'parent-tips';

-- Restore ai_feature_config_feature_check to the 2-value form. 009502 created
-- the table with an inline CHECK (feature IN ('tagging','event-review')) named
-- ai_feature_config_feature_check; 009702 dropped it and re-added with
-- 'parent-tips'. Reproduce the 2-value constraint under the same name.
ALTER TABLE public.ai_feature_config
  DROP CONSTRAINT IF EXISTS ai_feature_config_feature_check;
ALTER TABLE public.ai_feature_config
  ADD CONSTRAINT ai_feature_config_feature_check
    CHECK (feature IN ('tagging', 'event-review'));

-- Drop the parent_tips shape CHECK + its IMMUTABLE helper (INTRODUCED → drop).
-- Constraint first (it depends on the function).
ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_parent_tips_shape_chk;
DROP FUNCTION IF EXISTS private.parent_tips_is_valid(jsonb);

-- Drop the parent_tips columns (INTRODUCED by 009702 → drop).
-- (is_outdoor, images, latitude, longitude pre-exist in baseline — NOT touched.)
ALTER TABLE public.events
  DROP COLUMN IF EXISTS parent_tips,
  DROP COLUMN IF EXISTS parent_tips_generated_at,
  DROP COLUMN IF EXISTS parent_tips_provider,
  DROP COLUMN IF EXISTS parent_tips_model,
  DROP COLUMN IF EXISTS parent_tips_prompt_version;

-- ============================================================================
-- Reverse of source 009701: drop the two covering indexes on ai_feature_config
-- (INTRODUCED → drop). No prior versions existed.
-- ============================================================================
DROP INDEX IF EXISTS public.ai_feature_config_model_id_idx;
DROP INDEX IF EXISTS public.ai_feature_config_updated_by_idx;

-- ============================================================================
-- Reverse of sources 009600 / 009700 / 009800 / 009901
-- (geocodable-address heuristic, applied cumulatively to
-- list_events_needing_enrichment). Restore the pre-006000 body verbatim from
-- 20260601004000_llm_review_and_enrichment.sql:2178-2282 (source 009400) —
-- the version WITHOUT any _has_geocodable_address heuristic (needs_coords is
-- driven purely by _needs_coords).
-- ============================================================================
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
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH enrichment_flags AS (
    SELECT
      e.*,
      (
        (
          e.latitude IS NULL
          OR e.longitude IS NULL
          OR (
            c.latitude IS NOT NULL
            AND c.longitude IS NOT NULL
            AND e.latitude IS NOT NULL
            AND e.longitude IS NOT NULL
            AND abs(e.latitude  - c.latitude)  < 0.000001
            AND abs(e.longitude - c.longitude) < 0.000001
          )
        )
        AND NOT 'latitude'  = ANY(e.admin_locked_fields)
        AND NOT 'longitude' = ANY(e.admin_locked_fields)
      ) AS _needs_coords,
      (
        (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
        AND NOT 'images' = ANY(e.admin_locked_fields)
      ) AS _needs_images
    FROM public.events e
    LEFT JOIN public.cities c ON c.id = e.city_id
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    ef.id,
    ef.title,
    ef.description,
    ef.venue_name,
    ef.address,
    ef.city_id,
    ef.source_id,
    ef.source_url,
    ef._needs_coords  AS needs_coords,
    ef._needs_images  AS needs_images,
    ef.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[]) AS tags
  FROM enrichment_flags ef
  LEFT JOIN event_tag_slugs ets ON ets.event_id = ef.id
  WHERE ef._needs_coords OR ef._needs_images
  ORDER BY ef.last_enrichment_attempt_at ASC NULLS FIRST, ef.created_at DESC
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
  admin_locked_fields text[],
  tags          text[]
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

-- ============================================================================
-- Restore the v1 events_enriched (8-param, offset-based) verbatim from
-- 20260601000000_schema_baseline.sql:3592-3640, with its baseline grants.
-- (009902 dropped it; the canonical 9-param events_enriched it created was
-- dropped at the top of this script.) Done last among the events_enriched work
-- so the 8-param overload is distinct from the (now restored) v2.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.events_enriched(
  p_city_id   uuid DEFAULT NULL::uuid,
  p_status    text DEFAULT 'published'::text,
  p_limit     integer DEFAULT 100,
  p_offset    integer DEFAULT 0,
  p_user_id   uuid DEFAULT NULL::uuid,
  p_event_ids uuid[] DEFAULT NULL::uuid[],
  p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_date_to   timestamp with time zone DEFAULT NULL::timestamp with time zone
)
RETURNS TABLE (
  id               uuid,
  title            text,
  description      text,
  start_datetime   timestamp with time zone,
  end_datetime     timestamp with time zone,
  timezone         text,
  venue_name       text,
  address          text,
  city_id          uuid,
  latitude         numeric,
  longitude        numeric,
  age_min          integer,
  age_max          integer,
  price            numeric,
  is_free          boolean,
  source_url       text,
  source_name      text,
  source_id        uuid,
  images           jsonb,
  status           text,
  ai_confidence    numeric,
  ai_tag_provider  text,
  recurrence_info  jsonb,
  is_featured      boolean,
  view_count       integer,
  search_vector    tsvector,
  created_at       timestamp with time zone,
  updated_at       timestamp with time zone,
  avg_rating       numeric,
  rating_count     integer,
  tags             jsonb,
  is_favorited     boolean,
  is_in_calendar   boolean
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured, e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    (p_user_id IS NOT NULL AND f.event_id IS NOT NULL)  AS is_favorited,
    (p_user_id IS NOT NULL AND c.event_id IS NOT NULL)  AS is_in_calendar
  FROM public.events e
  LEFT JOIN LATERAL (
    SELECT ROUND(AVG(r.score)::numeric, 1) AS avg_score,
           COUNT(*)::int AS rating_count
    FROM public.ratings r
    WHERE r.event_id = e.id
  ) rs ON TRUE
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object('id', t.id, 'name', t.name, 'slug', t.slug, 'color', t.color)
             ORDER BY t.name
           ) AS tags
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    WHERE et.event_id = e.id
  ) ts ON TRUE
  LEFT JOIN public.favorites f
    ON p_user_id IS NOT NULL AND f.event_id = e.id AND f.user_id = p_user_id
  LEFT JOIN public.user_calendar_events c
    ON p_user_id IS NOT NULL AND c.event_id = e.id AND c.user_id = p_user_id
  WHERE
    (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (
      p_event_ids IS NOT NULL AND e.id = ANY(p_event_ids)
      OR p_event_ids IS NULL
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
  ORDER BY e.start_datetime ASC
  LIMIT  CASE WHEN p_event_ids IS NULL THEN p_limit  ELSE NULL END
  OFFSET CASE WHEN p_event_ids IS NULL THEN p_offset ELSE 0    END;
$$;

ALTER FUNCTION public.events_enriched(uuid, text, integer, integer, uuid, uuid[], timestamp with time zone, timestamp with time zone) OWNER TO postgres;
GRANT ALL ON FUNCTION public.events_enriched(uuid, text, integer, integer, uuid, uuid[], timestamp with time zone, timestamp with time zone) TO anon, authenticated, service_role;

COMMIT;
