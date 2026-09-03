BEGIN;

-- PostgreSQL requires ILIKE's ESCAPE expression to contain exactly one
-- character. The previous definition used the standard string '\\', which is
-- two backslashes when standard_conforming_strings is on. Use explicit escape
-- strings so keyword facets can safely match literal %, _, and \ characters.
CREATE OR REPLACE FUNCTION private.admin_event_facets(
  p_keyword text DEFAULT NULL::text
)
RETURNS TABLE (
  city_id uuid,
  source_id uuid,
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
        ELSE replace(
          replace(
            replace(btrim(p_keyword), E'\\', E'\\\\'),
            '%',
            E'\\%'
          ),
          '_',
          E'\\_'
        )
      END AS escaped_kw
  )
  SELECT
    e.city_id,
    e.source_id,
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
          e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE E'\\'
          OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE E'\\'
        )
      )
    )
  GROUP BY e.city_id, e.source_id, e.status
  ORDER BY e.city_id, e.source_id, e.status;
END;
$$;

COMMIT;
