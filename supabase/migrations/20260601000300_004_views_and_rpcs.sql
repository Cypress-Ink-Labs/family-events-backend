/*
  # Family Events Platform — Views & Query RPCs

  Read-only query surface: views for anon access, RPCs for enriched/filtered
  event fetching and plan generation.
*/

-- =============================================
-- event_rating_stats view
-- Collapses per-event ratings into avg + count so clients never fetch
-- raw rating rows to aggregate client-side.
-- security_invoker: anon SELECT on ratings (published events only) gates access.
-- =============================================
CREATE OR REPLACE VIEW public.event_rating_stats
WITH (security_invoker = true) AS
SELECT
  event_id,
  ROUND(AVG(score)::numeric, 1) AS avg_score,
  COUNT(*)::int AS rating_count
FROM public.ratings
GROUP BY event_id;

GRANT SELECT ON public.event_rating_stats TO anon, authenticated;

-- public_events view is defined in 001_schema.sql so that anon policies in
-- 003_rls.sql can reference it inside their USING clauses.

-- =============================================
-- search_events RPC
-- Server-side filtering; replaces fetch-all-then-filter.
-- SECURITY INVOKER: RLS on events gates access.
-- Not available to anon — use public_events view for unauthenticated reads.
-- =============================================
CREATE OR REPLACE FUNCTION public.search_events(
  p_city_id    uuid DEFAULT NULL,
  p_date_from  timestamptz DEFAULT NULL,
  p_date_to    timestamptz DEFAULT NULL,
  p_age_min    int DEFAULT NULL,
  p_age_max    int DEFAULT NULL,
  p_is_free    boolean DEFAULT NULL,
  p_is_featured boolean DEFAULT NULL,
  p_tag_slugs  text[] DEFAULT NULL,
  p_keyword    text DEFAULT NULL,
  p_status     text DEFAULT 'published',
  p_limit      int DEFAULT 100,
  p_offset     int DEFAULT 0
)
RETURNS SETOF public.events
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
    AND (p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min)
    AND (p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max)
    -- p_keyword MUST be sanitized by the caller (sanitizePostgrestLike in src/lib/utils.ts)
    AND (
      p_keyword IS NULL OR p_keyword = ''
      OR e.title ILIKE '%' || p_keyword || '%'
      OR e.description ILIKE '%' || p_keyword || '%'
    )
    -- Tag AND: event must have ALL requested slugs
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
  ORDER BY e.start_datetime ASC
  LIMIT p_limit OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.search_events TO authenticated;

-- =============================================
-- events_enriched RPC (8-param, final form)
-- Single-call enrichment for list + detail + calendar pages.
-- Collapses: events + tags + ratings + favorites + user_calendar_events.
--
-- p_event_ids overrides city/status/limit/offset (specific-IDs fetch path).
-- p_date_from / p_date_to apply to all call paths.
-- avg_rating / rating_count / tags default to 0 / 0 / [] (never NULL).
-- is_favorited / is_in_calendar return false when p_user_id IS NULL.
-- =============================================
CREATE OR REPLACE FUNCTION public.events_enriched(
  p_city_id    uuid DEFAULT NULL,
  p_status     text DEFAULT 'published',
  p_limit      int DEFAULT 100,
  p_offset     int DEFAULT 0,
  p_user_id    uuid DEFAULT NULL,
  p_event_ids  uuid[] DEFAULT NULL,
  p_date_from  timestamptz DEFAULT NULL,
  p_date_to    timestamptz DEFAULT NULL
)
RETURNS TABLE (
  id              uuid,
  title           text,
  description     text,
  start_datetime  timestamptz,
  end_datetime    timestamptz,
  timezone        text,
  venue_name      text,
  address         text,
  city_id         uuid,
  latitude        numeric,
  longitude       numeric,
  age_min         int,
  age_max         int,
  price           numeric,
  is_free         boolean,
  source_url      text,
  source_name     text,
  source_id       uuid,
  images          jsonb,
  status          text,
  ai_confidence   numeric,
  ai_tag_provider text,
  recurrence_info jsonb,
  is_featured     boolean,
  view_count      int,
  search_vector   tsvector,
  created_at      timestamptz,
  updated_at      timestamptz,
  avg_rating      numeric,
  rating_count    int,
  tags            jsonb,
  is_favorited    boolean,
  is_in_calendar  boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
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

GRANT EXECUTE ON FUNCTION public.events_enriched(uuid, text, int, int, uuid, uuid[], timestamptz, timestamptz)
  TO anon, authenticated;

-- =============================================
-- plan_events_for_user RPC
-- Composite scoring: distance*0.40 + weather*0.25 + age*0.20 + history_affinity*0.15
-- Requires cube + earthdistance extensions (installed in schema file).
--
-- Authorization: p_user_id MUST match auth.uid() (unless caller is admin).
-- Otherwise a logged-in user could probe another user's favorite-tag affinity
-- by passing their UUID. NULL p_user_id is allowed and means "no history".
-- =============================================
CREATE OR REPLACE FUNCTION public.plan_events_for_user(
  p_user_id    uuid,
  p_date       date DEFAULT (now() AT TIME ZONE 'utc')::date,
  p_city_id    uuid DEFAULT NULL,
  p_lat        double precision DEFAULT NULL,
  p_lng        double precision DEFAULT NULL,
  p_kid_age    integer DEFAULT NULL,
  p_weather_fit text DEFAULT 'neutral',
  p_limit      integer DEFAULT 3
)
RETURNS TABLE (
  event_id         uuid,
  score            numeric,
  distance_score   numeric,
  weather_score    numeric,
  age_score        numeric,
  history_affinity numeric,
  distance_km      numeric
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id IS NOT NULL
     AND p_user_id IS DISTINCT FROM auth.uid()
     AND NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden: p_user_id must match auth.uid()'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH user_favorite_tags AS (
    SELECT et.tag_id
    FROM public.favorites f
    JOIN public.event_tags et ON et.event_id = f.event_id
    WHERE f.user_id = p_user_id
    GROUP BY et.tag_id
  ),
  candidate_events AS (
    SELECT e.id, e.age_min, e.age_max, e.latitude, e.longitude, e.is_outdoor
    FROM public.events e
    WHERE e.status = 'published'
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND e.start_datetime::date = p_date
  ),
  event_history AS (
    SELECT
      et.event_id,
      COUNT(et.tag_id)::numeric AS tag_count,
      COUNT(et.tag_id) FILTER (WHERE uft.tag_id IS NOT NULL)::numeric AS matching_tag_count
    FROM public.event_tags et
    JOIN candidate_events ce ON ce.id = et.event_id
    LEFT JOIN user_favorite_tags uft ON uft.tag_id = et.tag_id
    GROUP BY et.event_id
  ),
  scored_events AS (
    SELECT
      e.id AS event_id,
      CASE
        WHEN p_lat IS NULL OR p_lng IS NULL OR e.latitude IS NULL OR e.longitude IS NULL THEN NULL
        ELSE public.earth_distance(
          public.ll_to_earth(p_lat, p_lng),
          public.ll_to_earth(e.latitude, e.longitude)
        ) / 1000.0
      END AS distance_km,
      CASE
        WHEN p_lat IS NULL OR p_lng IS NULL OR e.latitude IS NULL OR e.longitude IS NULL THEN 0.50
        ELSE GREATEST(0.0, 1.0 - LEAST(
          public.earth_distance(
            public.ll_to_earth(p_lat, p_lng),
            public.ll_to_earth(e.latitude, e.longitude)
          ) / 1000.0,
          50.0
        ) / 50.0)
      END AS distance_score,
      CASE LOWER(COALESCE(p_weather_fit, 'neutral'))
        WHEN 'outdoor' THEN CASE WHEN e.is_outdoor IS TRUE  THEN 1.0 ELSE 0.0 END
        WHEN 'indoor'  THEN CASE WHEN e.is_outdoor IS FALSE THEN 1.0 ELSE 0.0 END
        ELSE 0.50
      END AS weather_score,
      CASE
        WHEN p_kid_age IS NULL THEN 0.50
        WHEN e.age_min IS NULL AND e.age_max IS NULL THEN 0.50
        WHEN p_kid_age BETWEEN COALESCE(e.age_min, p_kid_age) AND COALESCE(e.age_max, p_kid_age) THEN 1.0
        ELSE 0.0
      END AS age_score,
      COALESCE(
        CASE
          WHEN history.tag_count = 0 THEN 0.0
          ELSE history.matching_tag_count / history.tag_count
        END,
        0.0
      ) AS history_affinity
    FROM candidate_events e
    LEFT JOIN event_history history ON history.event_id = e.id
  )
  SELECT
    se.event_id,
    ROUND((se.distance_score * 0.40 + se.weather_score * 0.25 + se.age_score * 0.20 + se.history_affinity * 0.15)::numeric, 6) AS score,
    ROUND(se.distance_score::numeric,   6) AS distance_score,
    ROUND(se.weather_score::numeric,    6) AS weather_score,
    ROUND(se.age_score::numeric,        6) AS age_score,
    ROUND(se.history_affinity::numeric, 6) AS history_affinity,
    CASE WHEN se.distance_km IS NULL THEN NULL ELSE ROUND(se.distance_km::numeric, 3) END AS distance_km
  FROM scored_events se
  ORDER BY score DESC, distance_km ASC NULLS LAST, event_id ASC
  LIMIT GREATEST(COALESCE(p_limit, 3), 1);
END;
$$;

GRANT EXECUTE ON FUNCTION public.plan_events_for_user(uuid, date, uuid, double precision, double precision, integer, text, integer)
  TO authenticated;
