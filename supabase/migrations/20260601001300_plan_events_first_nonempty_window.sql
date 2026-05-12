-- Phase 5.1: consolidate the 0..7-day plan_events loop into a single RPC.
-- ----------------------------------------------------------------
-- Previously the frontend issued up to 8 sequential RPC calls to
-- plan_events_for_user until one returned rows. On cold sessions this
-- dominated plan-page TTI. Now the loop lives in PL/pgSQL and short-
-- circuits on the first non-empty day; the frontend gets one roundtrip.
--
-- The returned row shape mirrors plan_events_for_user with one extra
-- day_offset column so the caller can derive selectedDate without a
-- second query.

BEGIN;

CREATE OR REPLACE FUNCTION public.plan_events_first_nonempty_window(
  p_user_id     uuid,
  p_date        date DEFAULT (now() AT TIME ZONE 'utc')::date,
  p_city_id     uuid DEFAULT NULL,
  p_lat         double precision DEFAULT NULL,
  p_lng         double precision DEFAULT NULL,
  p_kid_age     integer DEFAULT NULL,
  p_weather_fit text DEFAULT 'neutral',
  p_limit       integer DEFAULT 3,
  p_max_days    integer DEFAULT 7
)
RETURNS TABLE (
  day_offset       int,
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
DECLARE
  v_offset int;
  v_found  boolean := false;
BEGIN
  IF p_user_id IS NOT NULL
     AND p_user_id IS DISTINCT FROM auth.uid()
     AND NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden: p_user_id must match auth.uid()'
      USING ERRCODE = '42501';
  END IF;

  -- Cap p_max_days so a buggy caller can't spin 365 iterations.
  IF p_max_days IS NULL OR p_max_days < 0 THEN
    p_max_days := 0;
  ELSIF p_max_days > 14 THEN
    p_max_days := 14;
  END IF;

  FOR v_offset IN 0..p_max_days LOOP
    RETURN QUERY
    SELECT
      v_offset AS day_offset,
      pe.event_id,
      pe.score,
      pe.distance_score,
      pe.weather_score,
      pe.age_score,
      pe.history_affinity,
      pe.distance_km
    FROM public.plan_events_for_user(
      p_user_id,
      (p_date + (v_offset || ' days')::interval)::date,
      p_city_id, p_lat, p_lng, p_kid_age, p_weather_fit, p_limit
    ) pe;

    -- FOUND reflects whether the most recent RETURN QUERY produced rows.
    -- Once we have a non-empty day, stop iterating.
    IF FOUND THEN
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    -- Empty result already returned implicitly; no further action.
    RETURN;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
) IS
  'Returns the first non-empty day (offset 0..p_max_days, capped at 14) from
   plan_events_for_user. day_offset is included on every row so the caller
   can derive the selected date. Authorization mirrors plan_events_for_user:
   p_user_id must match auth.uid() unless caller is admin.';

GRANT EXECUTE ON FUNCTION public.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
) TO authenticated;

COMMIT;
