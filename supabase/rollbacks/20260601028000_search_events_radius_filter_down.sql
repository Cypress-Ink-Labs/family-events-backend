-- Rollback for 20260601028000_search_events_radius_filter.sql
-- Reverts:
--   - Drops the radius-extended public.search_events(... p_lat, p_lng, p_radius_km)
--     signature introduced by this migration
--   - Restores the prior public.search_events definition verbatim
--     (copied from 20260601017000_event_status_enum_and_validate_checks.sql UP,
--     lines 724-795 — the enum-aware version that casts e.status::text = p_status)
--
-- NOTE: The pre-028000 definition was last written by migration
-- 20260601017000_event_status_enum_and_validate_checks.sql (the UP migration).
-- The body below is copied verbatim from that UP migration file.

BEGIN;

-- 1. Drop the radius-extended signature.
DROP FUNCTION IF EXISTS public.search_events(
  uuid,           -- p_city_id
  timestamptz,    -- p_date_from
  timestamptz,    -- p_date_to
  integer,        -- p_age_min
  integer,        -- p_age_max
  boolean,        -- p_is_free
  boolean,        -- p_is_featured
  text[],         -- p_tag_slugs
  text,           -- p_keyword
  text,           -- p_status
  integer,        -- p_limit
  integer,        -- p_offset
  timestamptz,    -- p_after_start_datetime
  uuid,           -- p_after_id
  double precision, -- p_lat
  double precision, -- p_lng
  double precision  -- p_radius_km
);

-- 2. Restore the prior definition (14-parameter, no radius params).
--    Body copied verbatim from 20260601017000_event_status_enum_and_validate_checks.sql UP,
--    lines 724-795.
CREATE OR REPLACE FUNCTION public.search_events(p_city_id uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_age_min integer DEFAULT NULL::integer, p_age_max integer DEFAULT NULL::integer, p_is_free boolean DEFAULT NULL::boolean, p_is_featured boolean DEFAULT NULL::boolean, p_tag_slugs text[] DEFAULT NULL::text[], p_keyword text DEFAULT NULL::text, p_status text DEFAULT 'published'::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_after_start_datetime timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id uuid DEFAULT NULL::uuid)
 RETURNS SETOF events
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
  WHERE e.status::text = p_status
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
$function$;

REVOKE ALL ON FUNCTION public.search_events(uuid, timestamptz, timestamptz, integer, integer, boolean, boolean, text[], text, text, integer, integer, timestamptz, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_events(uuid, timestamptz, timestamptz, integer, integer, boolean, boolean, text[], text, text, integer, integer, timestamptz, uuid)
  TO anon, authenticated, service_role;

COMMIT;
