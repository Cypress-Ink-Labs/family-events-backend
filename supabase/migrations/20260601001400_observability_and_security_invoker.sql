-- Phase 7 (deferred audit items)
-- ----------------------------------------------------------------
-- Three independent hardening items bundled because none alone justifies
-- its own migration:
--   1. recommendation_signals retention + index (was: unbounded growth)
--   2. GIN index on admin_audit_log.metadata (was: slow jsonb scans)
--   3. plan_events_for_user → SECURITY INVOKER (was: bypassed RLS)

BEGIN;

-- =============================================
-- 1. recommendation_signals retention + read index
-- =============================================
-- Every view/favorite/calendar/rating/comment writes a row; without
-- retention the table grows forever. Daily delete of rows older than 90
-- days keeps the table bounded while preserving enough history for the
-- recommender's affinity heuristics.
CREATE INDEX IF NOT EXISTS recommendation_signals_user_created_idx
  ON public.recommendation_signals (user_id, created_at DESC);

DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('recommendation-signals-prune-daily');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Unexpected error unscheduling recommendation-signals-prune-daily: %', SQLERRM;
  END;
  PERFORM cron.schedule(
    'recommendation-signals-prune-daily',
    '30 3 * * *',
    $sql$
      DELETE FROM public.recommendation_signals
      WHERE created_at < now() - interval '90 days';
    $sql$
  );
END $$;

-- =============================================
-- 2. GIN index on admin_audit_log.metadata
-- =============================================
-- Audit log queries filter by metadata->>'enable', metadata @> '{"role":"admin"}',
-- etc. Without GIN, these scan the full table. Cheap to add; the audit log
-- is admin-only, so the index isn't hot.
CREATE INDEX IF NOT EXISTS admin_audit_log_metadata_idx
  ON public.admin_audit_log USING gin (metadata);

-- =============================================
-- 3. plan_events_for_user → SECURITY INVOKER
-- =============================================
-- The function already enforces "p_user_id = auth.uid() OR is_admin()" at
-- the top. As SECURITY DEFINER it bypassed RLS on favorites/event_tags,
-- which meant a future RLS tightening would not propagate here.
-- SECURITY INVOKER runs as the caller, so the existing RLS on favorites
-- (auth.uid() = user_id) and event_tags (has_enabled_access + published)
-- gate access automatically.
--
-- Compatibility note: the admin-querying-for-another-user path no longer
-- works without a separate admin-only RPC. Not used by the frontend today;
-- if it becomes needed, add a sibling admin_plan_events_for_user.
CREATE OR REPLACE FUNCTION public.plan_events_for_user(
  p_user_id     uuid,
  p_date        date DEFAULT (now() AT TIME ZONE 'utc')::date,
  p_city_id     uuid DEFAULT NULL,
  p_lat         double precision DEFAULT NULL,
  p_lng         double precision DEFAULT NULL,
  p_kid_age     integer DEFAULT NULL,
  p_weather_fit text DEFAULT 'neutral',
  p_limit       integer DEFAULT 3
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
        ELSE public.earth_distance(
          public.ll_to_earth(p_lat, p_lng),
          public.ll_to_earth(e.latitude, e.longitude)
        ) / 1000.0
      END AS distance_km,
      CASE
        WHEN p_lat IS NULL OR p_lng IS NULL OR e.latitude IS NULL OR e.longitude IS NULL THEN 0.50
        ELSE GREATEST(
          0.0,
          1.0 - (
            public.earth_distance(
              public.ll_to_earth(p_lat, p_lng),
              public.ll_to_earth(e.latitude, e.longitude)
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
$$;

GRANT EXECUTE ON FUNCTION public.plan_events_for_user(
  uuid, date, uuid, double precision, double precision, integer, text, integer
) TO authenticated;

COMMIT;
