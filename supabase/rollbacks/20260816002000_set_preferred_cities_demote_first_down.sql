-- Rollback for 20260816002000_set_preferred_cities_demote_first.sql
--
-- Restores the original function body from 20260620050000 (single set-based
-- upsert, no demote-first statement). Note: the restored body carries the
-- order-dependent primary-flip bug this migration fixed — rolling back
-- reintroduces it by design.

CREATE OR REPLACE FUNCTION public.set_preferred_cities(
  p_city_ids        uuid[],
  p_primary_city_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'set_preferred_cities: no authenticated user (auth.uid() is null)';
  END IF;

  IF p_city_ids IS NULL OR array_length(p_city_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'set_preferred_cities: p_city_ids must be a non-empty array';
  END IF;

  IF p_primary_city_id IS NULL OR NOT (p_primary_city_id = ANY (p_city_ids)) THEN
    RAISE EXCEPTION
      'set_preferred_cities: p_primary_city_id (%) must be one of p_city_ids',
      p_primary_city_id;
  END IF;

  DELETE FROM public.user_preferred_cities
  WHERE user_id = v_uid
    AND city_id <> ALL (p_city_ids);

  INSERT INTO public.user_preferred_cities (user_id, city_id, is_primary)
  SELECT v_uid, c.city_id, (c.city_id = p_primary_city_id)
  FROM unnest(p_city_ids) AS c(city_id)
  ON CONFLICT (user_id, city_id)
  DO UPDATE SET is_primary = excluded.is_primary;

  UPDATE public.user_profiles
  SET city_preference_id = p_primary_city_id
  WHERE id = v_uid;
END;
$$;

COMMENT ON FUNCTION public.set_preferred_cities(uuid[], uuid) IS
  'Atomically replaces the calling user''s public.user_preferred_cities rows '
  'with p_city_ids (is_primary set on p_primary_city_id) and mirrors '
  'public.user_profiles.city_preference_id to the chosen primary, in one '
  'transaction. SECURITY INVOKER so owner-only RLS applies. authenticated only. '
  'Replaces the non-atomic multi-statement client sequence (CIL-187).';
