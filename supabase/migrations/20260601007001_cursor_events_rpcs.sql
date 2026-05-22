-- §2: Cursor-based pagination RPCs for events_enriched and search_events.

BEGIN;

-- ---------------------------------------------------------------------------
-- Indexes: composite (start_datetime, id) for keyset pagination.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS events_published_start_id_idx
  ON public.events (start_datetime, id)
  WHERE status = 'published';

-- events_published_city_start_id_idx duplicates events_published_feed_idx from
-- 006800; dropped in 007600 to keep advisor lint clean.

-- ---------------------------------------------------------------------------
-- Function 1: events_enriched_v2
-- Adds keyset cursor params (p_after_start_datetime, p_after_id) to v1.
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Function 2: search_events_v2
-- Adds keyset cursor params to v1; cursor takes priority over p_offset when
-- p_after_start_datetime IS NOT NULL.
-- ---------------------------------------------------------------------------

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

COMMIT;
