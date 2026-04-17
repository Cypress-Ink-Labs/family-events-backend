/*
  # Server-side event search RPC

  Replaces the fetch-all-then-filter pattern in use-events.ts. The old flow
  queried every published event in a city, then filtered age_min/age_max,
  is_free, tag slugs, and keyword client-side after paying the full transfer
  cost for N event rows.

  This RPC pushes every filter to Postgres so clients only fetch the N rows
  they'll actually render. Returns plain events; enrichment (tags, city,
  ratings, favorites, calendar) still happens in TS via enrichEvents().
*/

CREATE OR REPLACE FUNCTION search_events(
  p_city_id uuid DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_age_min int DEFAULT NULL,
  p_age_max int DEFAULT NULL,
  p_is_free boolean DEFAULT NULL,
  p_is_featured boolean DEFAULT NULL,
  p_tag_slugs text[] DEFAULT NULL,
  p_keyword text DEFAULT NULL,
  p_status text DEFAULT 'published',
  p_limit int DEFAULT 100,
  p_offset int DEFAULT 0
)
RETURNS SETOF events
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT e.*
  FROM public.events e
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
    AND (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (p_is_free IS NULL OR e.is_free = p_is_free)
    AND (p_is_featured IS NULL OR e.is_featured = p_is_featured)
    -- Age overlap: event [age_min..age_max] overlaps with filter [p_age_min..p_age_max]
    AND (
      p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min
    )
    AND (
      p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max
    )
    -- Keyword search on title or description.
    -- IMPORTANT: p_keyword MUST be sanitized by the caller (sanitizePostgrestLike in
    -- src/lib/utils.ts) before passing to this function. The TS layer strips PostgREST
    -- and SQL LIKE reserved characters (%, _, backslash, etc.).
    AND (
      p_keyword IS NULL OR p_keyword = ''
      OR e.title ILIKE '%' || p_keyword || '%'
      OR e.description ILIKE '%' || p_keyword || '%'
    )
    -- Tag AND: event must have ALL requested tag slugs.
    -- No additional index needed: event_tags PRIMARY KEY (event_id, tag_id) covers event_id
    -- lookups and tags.slug has a UNIQUE constraint. A LATERAL JOIN refactor can be
    -- considered if profiling shows this correlated subquery is a bottleneck.
    AND (
      p_tag_slugs IS NULL
      OR array_length(p_tag_slugs, 1) IS NULL
      OR (
        SELECT COUNT(DISTINCT t.slug)
        FROM public.event_tags et
        JOIN public.tags t ON t.id = et.tag_id
        WHERE et.event_id = e.id
          AND t.slug = ANY(p_tag_slugs)
      ) = array_length(p_tag_slugs, 1)
    )
  ORDER BY e.start_datetime ASC
  LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION search_events IS
  'Server-side event filtering. Replaces fetch-all-then-filter pattern. RLS applies via SECURITY INVOKER.';

GRANT EXECUTE ON FUNCTION search_events TO anon, authenticated;
