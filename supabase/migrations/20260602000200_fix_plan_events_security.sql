-- Fix: plan_events_for_user was SECURITY INVOKER but calls private.is_admin(),
-- which requires USAGE on the private schema. Authenticated users don't have
-- that grant (and shouldn't — private schema is for internal helpers only).
--
-- SECURITY DEFINER is correct here: the function's WHERE clauses already enforce
-- the same access control that RLS would (status='published', user_id=p_user_id
-- validated against auth.uid()). The private.is_admin() call works because the
-- function now runs as its owner, who has access to the private schema.
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
SECURITY DEFINER
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
      AND (e.start_datetime AT TIME ZONE e.timezone)::date = p_date
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

REVOKE ALL ON FUNCTION public.plan_events_for_user(uuid, date, uuid, double precision, double precision, integer, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.plan_events_for_user(uuid, date, uuid, double precision, double precision, integer, text, integer)
  TO authenticated;
