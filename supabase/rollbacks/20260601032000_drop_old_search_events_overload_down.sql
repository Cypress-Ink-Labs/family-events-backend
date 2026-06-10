-- Rollback for 20260601032000_drop_old_search_events_overload.sql
-- Reverts the DROP of two old function overloads by recreating them verbatim:
--   1. public.search_events (14-param, no radius) — body from
--      20260601017000_event_status_enum_and_validate_checks.sql UP, lines 724-795
--   2. public.admin_update_event (4-param wrapper) — body from
--      20260601000000_schema_baseline.sql
-- NOTE: 032000 dropped only public.search_events (14-param) and
--       public.admin_update_event (4-param). It did NOT drop private.admin_update_event.
-- NOTE: Recreating these overloads will re-introduce the PGRST203 disambiguation
-- ambiguity that 032000 was written to fix. Only run this rollback if you also
-- intend to roll back 028000 (radius) and 021000 (decision_reason).

BEGIN;

-- 1. Recreate public.search_events 14-param overload (no radius params).
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

-- 2. Recreate public.admin_update_event 4-param wrapper.
--    Body copied verbatim from 20260601000000_schema_baseline.sql.
--    NOTE: 032000 dropped only this public wrapper; private.admin_update_event was NOT dropped.
--    check_function_bodies must be off: after 021000 both 4-param and 5-param
--    private.admin_update_event overloads exist, so this body is ambiguous at
--    validation time — exactly the latent PGRST203 state that existed before
--    032000 and that 032000 was written to fix.
SET LOCAL check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.admin_update_event(
  p_event_id uuid,
  p_patch jsonb,
  p_tag_ids uuid[],
  p_lock_edited_fields boolean DEFAULT true
)
RETURNS public.events
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_update_event(p_event_id, p_patch, p_tag_ids, p_lock_edited_fields);
$$;

ALTER FUNCTION public.admin_update_event(uuid, jsonb, uuid[], boolean) OWNER TO postgres;

GRANT ALL ON FUNCTION public.admin_update_event(uuid, jsonb, uuid[], boolean) TO authenticated, service_role;

COMMIT;
