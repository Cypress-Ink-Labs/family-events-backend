-- Migration: 20260620030000_plan_events_for_user_range.sql
--
-- Introduces public.plan_events_for_user_range(), an 8-factor, date-range,
-- multi-city scoring RPC for the weekend digest edge function.
--
-- Design notes:
--   • This is a NEW function (additive). The existing single-date
--     public.plan_events_for_user() is NOT modified.
--   • Called by the send-weekly-digest edge function as service_role (auth.uid()
--     is NULL in that context). The auth-uid guard present in the original RPC
--     is intentionally OMITTED here — it would block every service-role call.
--     Security is enforced by grants (service_role only; no PUBLIC, no anon,
--     no authenticated).
--   • SECURITY DEFINER + SET search_path TO '' follows the pattern in
--     20260618000000_find_similar_events_by_id_security_definer.sql.
--
-- Paired rollback:
--   supabase/rollbacks/20260620030000_plan_events_for_user_range_down.sql
--
-- Manual verification steps (no live DB in CI):
--   1. Apply migration: pnpm run db:migrate
--   2. Confirm function exists:
--        SELECT proname FROM pg_proc
--        JOIN pg_namespace ns ON ns.oid = pronamespace
--        WHERE ns.nspname = 'public' AND proname = 'plan_events_for_user_range';
--   3. Smoke-call (requires published events with start_datetime in range):
--        SELECT * FROM public.plan_events_for_user_range(
--          p_user_id   := '<some-uuid>',
--          p_date_from := now(),
--          p_date_to   := now() + interval '7 days'
--        );
--   4. Verify factor ranges are in [0, 1]:
--        All *_score columns should be between 0.0 and 1.0.
--   5. Verify grant: service_role can call it; authenticated/anon cannot.

-- ─── Function ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.plan_events_for_user_range(
  p_user_id     uuid,
  p_date_from   timestamptz,
  p_date_to     timestamptz,
  p_city_ids    uuid[]            DEFAULT NULL,
  p_lat         double precision  DEFAULT NULL,
  p_lng         double precision  DEFAULT NULL,
  p_kid_age     integer           DEFAULT NULL,
  p_weather_fit text              DEFAULT 'neutral',
  p_limit       integer           DEFAULT 5
)
RETURNS TABLE (
  event_id         uuid,
  score            numeric,
  distance_score   numeric,
  weather_score    numeric,
  age_score        numeric,
  history_affinity numeric,
  family_fit_score numeric,
  timing_score     numeric,
  novelty_score    numeric,
  budget_score     numeric,
  distance_km      numeric,
  start_datetime   timestamptz,
  city_id          uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  RETURN QUERY
  WITH
  -- ── 1. Tags the user has engaged with via favorites ──────────────────────
  user_favorite_tags AS (
    SELECT et.tag_id
    FROM public.favorites f
    JOIN public.event_tags et ON et.event_id = f.event_id
    WHERE f.user_id = p_user_id
    GROUP BY et.tag_id
  ),

  -- ── 2. Candidate events within the date range and optional city filter ───
  candidate_events AS (
    SELECT
      e.id,
      e.age_min,
      e.age_max,
      e.latitude,
      e.longitude,
      e.is_outdoor,
      e.start_datetime,
      e.timezone,
      e.price,
      e.is_free,
      e.created_at,
      e.city_id
    FROM public.events e
    WHERE e.status = 'published'
      AND (p_city_ids IS NULL OR e.city_id = ANY(p_city_ids))
      AND e.start_datetime BETWEEN p_date_from AND p_date_to
  ),

  -- ── 3. History-affinity: tag overlap with user's favorited events ─────────
  event_history AS (
    SELECT
      et.event_id,
      COUNT(et.tag_id)::numeric                                            AS tag_count,
      COUNT(et.tag_id) FILTER (WHERE uft.tag_id IS NOT NULL)::numeric     AS matching_tag_count
    FROM public.event_tags et
    JOIN candidate_events ce ON ce.id = et.event_id
    LEFT JOIN user_favorite_tags uft ON uft.tag_id = et.tag_id
    GROUP BY et.event_id
  ),

  -- ── 4. Family-fit tag counts per event ───────────────────────────────────
  -- Curated family-fit slugs (seeded in 20260601001000_reference_security_and_cron.sql):
  --   toddler-friendly, baby-friendly, teen-friendly, family-festival,
  --   storytime, playgroup, sensory-friendly
  family_fit_counts AS (
    SELECT
      et.event_id,
      COUNT(*)::numeric                                                    AS total_tag_count,
      COUNT(*) FILTER (
        WHERE t.slug IN (
          'toddler-friendly', 'baby-friendly', 'teen-friendly',
          'family-festival', 'storytime', 'playgroup', 'sensory-friendly'
        )
      )::numeric                                                           AS family_tag_count
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    JOIN candidate_events ce ON ce.id = et.event_id
    GROUP BY et.event_id
  ),

  -- ── 5. Score all 8 factors ────────────────────────────────────────────────
  scored_events AS (
    SELECT
      e.id            AS event_id,
      e.start_datetime,
      e.city_id,

      -- Distance (km from caller's location; NULL inputs → 0.50 neutral)
      CASE
        WHEN p_lat IS NULL OR p_lng IS NULL OR e.latitude IS NULL OR e.longitude IS NULL THEN NULL
        ELSE extensions.earth_distance(
          extensions.ll_to_earth(p_lat, p_lng),
          extensions.ll_to_earth(e.latitude, e.longitude)
        ) / 1000.0
      END AS distance_km,

      -- FACTOR 1: distance_score  (50 km = 0.0; 0 km = 1.0; no coords = 0.50)
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

      -- FACTOR 2: weather_score  (outdoor/indoor preference vs. event type)
      CASE
        WHEN e.is_outdoor IS NULL           THEN 0.50
        WHEN p_weather_fit = 'outdoor'  AND     e.is_outdoor THEN 1.0
        WHEN p_weather_fit = 'indoor'   AND NOT e.is_outdoor THEN 1.0
        WHEN p_weather_fit = 'outdoor'  AND NOT e.is_outdoor THEN 0.20
        WHEN p_weather_fit = 'indoor'   AND     e.is_outdoor THEN 0.20
        ELSE 0.60
      END AS weather_score,

      -- FACTOR 3: age_score  (within range = 1.0; penalised ÷5 per year outside)
      CASE
        WHEN p_kid_age IS NULL THEN 0.50
        WHEN COALESCE(e.age_min, 0) <= p_kid_age
             AND COALESCE(e.age_max, 99) >= p_kid_age THEN 1.0
        ELSE GREATEST(
          0.0,
          1.0 - LEAST(
            ABS(COALESCE(e.age_min, p_kid_age) - p_kid_age),
            ABS(COALESCE(e.age_max, p_kid_age) - p_kid_age)
          )::numeric / 5.0
        )
      END AS age_score,

      -- FACTOR 4: history_affinity  (tag overlap with user's favorited events)
      CASE
        WHEN eh.tag_count IS NULL OR eh.tag_count = 0 THEN 0.0
        ELSE eh.matching_tag_count / eh.tag_count
      END AS history_affinity,

      -- FACTOR 5: family_fit_score
      --   fraction of the event's tags that are in the curated family-fit set;
      --   0.50 neutral when the event has zero tags (tagging may be pending).
      CASE
        WHEN ffc.total_tag_count IS NULL OR ffc.total_tag_count = 0 THEN 0.50
        ELSE ffc.family_tag_count / ffc.total_tag_count
      END AS family_fit_score,

      -- FACTOR 6: timing_score  (local time via timezone column)
      --   EXTRACT(DOW): 0=Sun, 5=Fri, 6=Sat
      CASE
        WHEN EXTRACT(DOW  FROM (e.start_datetime AT TIME ZONE e.timezone)) IN (0, 6)
             AND EXTRACT(HOUR FROM (e.start_datetime AT TIME ZONE e.timezone)) BETWEEN 9 AND 16
          THEN 1.0   -- Sat/Sun 09:00–16:59
        WHEN EXTRACT(DOW  FROM (e.start_datetime AT TIME ZONE e.timezone)) = 5
             AND EXTRACT(HOUR FROM (e.start_datetime AT TIME ZONE e.timezone)) >= 17
          THEN 0.9   -- Fri ≥17:00
        WHEN EXTRACT(DOW  FROM (e.start_datetime AT TIME ZONE e.timezone)) IN (0, 6)
             AND EXTRACT(HOUR FROM (e.start_datetime AT TIME ZONE e.timezone)) BETWEEN 17 AND 20
          THEN 0.7   -- Sat/Sun 17:00–20:59
        WHEN EXTRACT(DOW  FROM (e.start_datetime AT TIME ZONE e.timezone)) IN (0, 6)
          THEN 0.5   -- Sat/Sun other hours
        ELSE 0.4     -- weekday daytime or other
      END AS timing_score,

      -- FACTOR 7: novelty_score  (linear decay to 0 over 30 days)
      GREATEST(
        0.0,
        1.0 - (EXTRACT(EPOCH FROM (now() - e.created_at)) / 86400.0) / 30.0
      ) AS novelty_score,

      -- FACTOR 8: budget_score
      CASE
        WHEN e.is_free                 THEN 1.0
        WHEN e.price IS NOT NULL       THEN GREATEST(0.0, 1.0 - e.price / 50.0)
        ELSE 0.50
      END AS budget_score

    FROM candidate_events e
    LEFT JOIN event_history     eh  ON eh.event_id  = e.id
    LEFT JOIN family_fit_counts ffc ON ffc.event_id = e.id
  )

  -- ── 6. Final weighted SELECT ──────────────────────────────────────────────
  -- Weights (must sum to 1.0):
  --   distance 0.20 | weather 0.15 | age 0.15 | history 0.15
  --   family_fit 0.15 | timing 0.08 | novelty 0.07 | budget 0.05
  SELECT
    se.event_id,
    (
      se.distance_score   * 0.20
      + se.weather_score  * 0.15
      + se.age_score      * 0.15
      + se.history_affinity * 0.15
      + se.family_fit_score * 0.15
      + se.timing_score   * 0.08
      + se.novelty_score  * 0.07
      + se.budget_score   * 0.05
    )::numeric AS score,
    se.distance_score::numeric,
    se.weather_score::numeric,
    se.age_score::numeric,
    se.history_affinity::numeric,
    se.family_fit_score::numeric,
    se.timing_score::numeric,
    se.novelty_score::numeric,
    se.budget_score::numeric,
    se.distance_km::numeric,
    se.start_datetime,
    se.city_id
  FROM scored_events se
  ORDER BY score DESC, se.start_datetime ASC, se.event_id ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 100);

END;
$$;

-- ─── Grants ──────────────────────────────────────────────────────────────────
-- Service-role only: this RPC is called by the digest edge function where
-- auth.uid() is NULL. No public, anon, or authenticated access.

REVOKE ALL ON FUNCTION public.plan_events_for_user_range(
  uuid, timestamptz, timestamptz, uuid[], double precision, double precision,
  integer, text, integer
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.plan_events_for_user_range(
  uuid, timestamptz, timestamptz, uuid[], double precision, double precision,
  integer, text, integer
) TO service_role;

-- ─── Comment ─────────────────────────────────────────────────────────────────

COMMENT ON FUNCTION public.plan_events_for_user_range(
  uuid, timestamptz, timestamptz, uuid[], double precision, double precision,
  integer, text, integer
) IS
  'Service-role weekend digest ranker. '
  'Scores published events over a date range across one or more cities using '
  '8 weighted factors: distance, weather, age, history_affinity, family_fit, '
  'timing, novelty, and budget. '
  'Called by the send-weekly-digest edge function (auth.uid() is NULL); '
  'accessible to service_role only.';
