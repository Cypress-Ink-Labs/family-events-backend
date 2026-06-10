-- Rollback for 20260610170000_admin_events_source_filter.sql
-- Reverts:
--   - DROP private.admin_events_enriched (11-param, with p_source_id)
--   - DROP public.admin_events_enriched  (11-param, with p_source_id)
--   - DROP private.admin_event_facets    (returns city_id + source_id + status + count)
--   - DROP public.admin_event_facets     (returns city_id + source_id + status + count)
--   - RECREATE private.admin_events_enriched (10-param, no p_source_id) — body from
--     20260601017000_event_status_enum_and_validate_checks.sql UP, lines 798-900
--   - RECREATE public.admin_events_enriched  (10-param wrapper) — same source
--   - RECREATE private.admin_event_facets    (returns city_id + status + count, no source_id) — same source, lines 903-956
--   - RECREATE public.admin_event_facets     (wrapper) — same source
-- NOTE: admin_event_facets return type changes (loses source_id column).
-- Any callers relying on the source_id facet column will break after rollback.

BEGIN;

-- 1. Drop the 11-param (source-filter) variants introduced by 170000.
DROP FUNCTION IF EXISTS public.admin_events_enriched(
  text, uuid, boolean, text, timestamptz, uuid, int,
  public.llm_event_review_status, public.llm_event_review_decision, boolean, uuid
);
DROP FUNCTION IF EXISTS private.admin_events_enriched(
  text, uuid, boolean, text, timestamptz, uuid, int,
  public.llm_event_review_status, public.llm_event_review_decision, boolean, uuid
);
DROP FUNCTION IF EXISTS public.admin_event_facets(text);
DROP FUNCTION IF EXISTS private.admin_event_facets(text);

-- 2. Restore private.admin_events_enriched (10-param, no p_source_id).
--    Body copied verbatim from 20260601017000_event_status_enum_and_validate_checks.sql UP,
--    lines 798-900.
CREATE OR REPLACE FUNCTION private.admin_events_enriched(
  p_status               text                             DEFAULT NULL::text,
  p_city_id              uuid                             DEFAULT NULL::uuid,
  p_city_is_null         boolean                          DEFAULT NULL::boolean,
  p_keyword              text                             DEFAULT NULL::text,
  p_after_created_at     timestamp with time zone         DEFAULT NULL::timestamp with time zone,
  p_after_id             uuid                             DEFAULT NULL::uuid,
  p_limit                integer                          DEFAULT 50,
  p_llm_review_status    llm_event_review_status          DEFAULT NULL::llm_event_review_status,
  p_llm_review_decision  llm_event_review_decision        DEFAULT NULL::llm_event_review_decision,
  p_llm_reviewed         boolean                          DEFAULT NULL::boolean
)
RETURNS TABLE(
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamp with time zone,
  end_datetime          timestamp with time zone,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               integer,
  age_max               integer,
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
  view_count            integer,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamp with time zone,
  admin_last_edited_by  uuid,
  created_at            timestamp with time zone,
  updated_at            timestamp with time zone,
  ai_tag_model          text,
  ai_tag_status         text,
  llm_review_status     llm_event_review_status,
  llm_review_decision   llm_event_review_decision,
  llm_review_confidence numeric,
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamp with time zone,
  llm_review_error      text,
  total_count           bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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
      (p_status IS NULL OR e.status::text = p_status)
      AND (
        p_city_is_null IS NULL
        OR (p_city_is_null = true  AND e.city_id IS NULL)
        OR (p_city_is_null = false AND e.city_id IS NOT NULL)
      )
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (p_llm_review_status IS NULL OR e.llm_review_status = p_llm_review_status)
      AND (p_llm_review_decision IS NULL OR e.llm_review_decision = p_llm_review_decision)
      AND (
        p_llm_reviewed IS DISTINCT FROM true
        OR (
          e.llm_reviewed_at IS NOT NULL
          AND e.llm_review_decision IS NOT NULL
          AND e.llm_review_status <> 'failed'::public.llm_event_review_status
        )
      )
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
    p.source_url, p.source_name, p.source_id, p.images, p.status::text,
    p.ai_confidence, p.ai_tag_provider, p.recurrence_info, p.is_featured, p.view_count,
    p.search_vector, p.admin_locked_fields, p.admin_last_edited_at, p.admin_last_edited_by,
    p.created_at, p.updated_at, p.ai_tag_model, p.ai_tag_status,
    p.llm_review_status, p.llm_review_decision, p.llm_review_confidence, p.llm_review_reason,
    p.llm_review_flags, p.llm_review_provider, p.llm_review_model, p.llm_review_prompt_version,
    p.llm_reviewed_at, p.llm_review_error,
    p.total_count
  FROM page p;
END;
$function$;

-- 3. Restore public.admin_events_enriched (10-param wrapper).
--    Body copied verbatim from 20260601017000_event_status_enum_and_validate_checks.sql UP.
CREATE OR REPLACE FUNCTION public.admin_events_enriched(
  p_status               text                             DEFAULT NULL::text,
  p_city_id              uuid                             DEFAULT NULL::uuid,
  p_city_is_null         boolean                          DEFAULT NULL::boolean,
  p_keyword              text                             DEFAULT NULL::text,
  p_after_created_at     timestamp with time zone         DEFAULT NULL::timestamp with time zone,
  p_after_id             uuid                             DEFAULT NULL::uuid,
  p_limit                integer                          DEFAULT 50,
  p_llm_review_status    llm_event_review_status          DEFAULT NULL::llm_event_review_status,
  p_llm_review_decision  llm_event_review_decision        DEFAULT NULL::llm_event_review_decision,
  p_llm_reviewed         boolean                          DEFAULT NULL::boolean
)
RETURNS TABLE(
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamp with time zone,
  end_datetime          timestamp with time zone,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               integer,
  age_max               integer,
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
  view_count            integer,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamp with time zone,
  admin_last_edited_by  uuid,
  created_at            timestamp with time zone,
  updated_at            timestamp with time zone,
  ai_tag_model          text,
  ai_tag_status         text,
  llm_review_status     llm_event_review_status,
  llm_review_decision   llm_event_review_decision,
  llm_review_confidence numeric,
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamp with time zone,
  llm_review_error      text,
  total_count           bigint
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT * FROM private.admin_events_enriched(
    p_status, p_city_id, p_city_is_null, p_keyword,
    p_after_created_at, p_after_id, p_limit,
    p_llm_review_status, p_llm_review_decision, p_llm_reviewed
  );
$function$;

-- 4. Restore private.admin_event_facets (returns city_id + status + count, no source_id).
--    Body copied verbatim from 20260601017000_event_status_enum_and_validate_checks.sql UP,
--    lines 903-956.
CREATE OR REPLACE FUNCTION private.admin_event_facets(p_keyword text DEFAULT NULL::text)
RETURNS TABLE(city_id uuid, status text, count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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
    e.status::text,
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
$function$;

-- 5. Restore public.admin_event_facets (wrapper, old 2-column return: city_id + status + count).
CREATE OR REPLACE FUNCTION public.admin_event_facets(p_keyword text DEFAULT NULL::text)
RETURNS TABLE(city_id uuid, status text, count bigint)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT * FROM private.admin_event_facets(p_keyword);
$function$;

-- 6. Restore grants (matching the pre-170000 grant pattern from 017000 rollback).
REVOKE EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, integer, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, integer, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, integer, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, integer, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  TO authenticated;

REVOKE EXECUTE ON FUNCTION private.admin_event_facets(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.admin_event_facets(text)
  TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.admin_event_facets(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_event_facets(text)
  TO authenticated;

COMMIT;
