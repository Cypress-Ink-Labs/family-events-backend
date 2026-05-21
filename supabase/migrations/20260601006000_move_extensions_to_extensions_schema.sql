/*
  # Move public-schema extensions to the `extensions` schema

  Closes advisor lint 0014_extension_in_public for `cube`, `earthdistance`,
  and `pg_net`. The `extensions` schema is provisioned by Supabase as the
  canonical home for Postgres extensions; keeping them in `public` mingles
  extension-provided functions with application objects and complicates
  grants and search_path management.

  - `cube` and `earthdistance` expose user-callable functions
    (`earth_distance`, `ll_to_earth`, …). `public.plan_events_for_user`
    calls these and pins `search_path = ''`, so the qualified names must
    be updated to `extensions.` after the move.
  - `pg_net` does NOT support `ALTER EXTENSION ... SET SCHEMA`
    (Postgres returns ERROR 0A000). The extension is hardcoded to live
    next to its `net` schema. Advisor lint 0014 will continue to flag
    pg_net until upstream adds relocatability; this is a platform
    limitation, not something a migration can fix.
  - GRANT USAGE on the `extensions` schema to anon + authenticated +
    service_role so SECURITY INVOKER callers can resolve the moved
    functions at runtime (mirrors the USAGE pattern in
    20260601002200/20260601005600).
*/

BEGIN;

ALTER EXTENSION cube          SET SCHEMA extensions;
ALTER EXTENSION earthdistance SET SCHEMA extensions;
-- pg_net intentionally omitted: ERROR 0A000 "extension pg_net does not
-- support SET SCHEMA". Leave it in public; advisor 0014 will keep
-- flagging it until upstream fixes relocatability.

GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

-- public.plan_events_for_user pins search_path = '' so it must qualify
-- every extension function by schema. After the move, public.earth_distance
-- and public.ll_to_earth no longer exist; rewrite the body to use the new
-- canonical schema. Function signature + return type unchanged.
CREATE OR REPLACE FUNCTION public.plan_events_for_user(
  p_user_id      uuid,
  p_date         date              DEFAULT ((now() AT TIME ZONE 'utc'::text))::date,
  p_city_id      uuid              DEFAULT NULL,
  p_lat          double precision  DEFAULT NULL,
  p_lng          double precision  DEFAULT NULL,
  p_kid_age      integer           DEFAULT NULL,
  p_weather_fit  text              DEFAULT 'neutral',
  p_limit        integer           DEFAULT 3
)
RETURNS TABLE (
  event_id          uuid,
  score             numeric,
  distance_score    numeric,
  weather_score     numeric,
  age_score         numeric,
  history_affinity  numeric,
  distance_km       numeric
)
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $function$
BEGIN
  IF p_user_id IS NOT NULL
     AND p_user_id IS DISTINCT FROM auth.uid() THEN
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
        ELSE extensions.earth_distance(
          extensions.ll_to_earth(p_lat, p_lng),
          extensions.ll_to_earth(e.latitude, e.longitude)
        ) / 1000.0
      END AS distance_km,
      CASE
        WHEN p_lat IS NULL OR p_lng IS NULL OR e.latitude IS NULL OR e.longitude IS NULL THEN 0.50
        ELSE GREATEST(
          0.0,
          1.0 - (
            extensions.earth_distance(
              extensions.ll_to_earth(p_lat, p_lng),
              extensions.ll_to_earth(e.latitude, e.longitude)
            ) / 1000.0
          ) / 50.0
        )
      END AS distance_score,
      CASE
        WHEN e.is_outdoor IS NULL THEN 0.50
        WHEN p_weather_fit = 'outdoor' AND e.is_outdoor THEN 1.0
        WHEN p_weather_fit = 'indoor' AND NOT e.is_outdoor THEN 1.0
        WHEN p_weather_fit = 'outdoor' AND NOT e.is_outdoor THEN 0.20
        WHEN p_weather_fit = 'indoor' AND e.is_outdoor THEN 0.20
        ELSE 0.60
      END AS weather_score,
      CASE
        WHEN p_kid_age IS NULL THEN 0.50
        WHEN COALESCE(e.age_min, 0) <= p_kid_age AND COALESCE(e.age_max, 99) >= p_kid_age THEN 1.0
        ELSE GREATEST(
          0.0,
          1.0 - LEAST(
            ABS(COALESCE(e.age_min, p_kid_age) - p_kid_age),
            ABS(COALESCE(e.age_max, p_kid_age) - p_kid_age)
          )::numeric / 5.0
        )
      END AS age_score,
      CASE
        WHEN eh.tag_count IS NULL OR eh.tag_count = 0 THEN 0.0
        ELSE eh.matching_tag_count / eh.tag_count
      END AS history_affinity
    FROM candidate_events e
    LEFT JOIN event_history eh ON eh.event_id = e.id
  )
  SELECT
    se.event_id,
    (se.distance_score * 0.40
     + se.weather_score * 0.25
     + se.age_score * 0.20
     + se.history_affinity * 0.15)::numeric AS score,
    se.distance_score::numeric,
    se.weather_score::numeric,
    se.age_score::numeric,
    se.history_affinity::numeric,
    se.distance_km::numeric
  FROM scored_events se
  ORDER BY score DESC
  LIMIT p_limit;
END;
$function$;

COMMIT;
