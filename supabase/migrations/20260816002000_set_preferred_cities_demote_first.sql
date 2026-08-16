-- Migration: 20260816002000_set_preferred_cities_demote_first.sql
--
-- Production readiness program (2026-08-14-001), found by the U6 data-layer
-- integration suite: public.set_preferred_cities fails with
--
--   duplicate key value violates unique constraint
--   "user_preferred_cities_one_primary"
--
-- whenever the NEW primary city precedes the CURRENT primary in p_city_ids.
-- The original body (20260620050000) relied on a single set-based
-- INSERT … ON CONFLICT … DO UPDATE and claimed the partial unique index is
-- "checked once, at statement end". That is wrong: non-deferrable unique
-- indexes are enforced per row. When the upsert promotes the new primary
-- before the row-level demote of the old one has been reached, both rows are
-- momentarily primary and the index raises. Whether a flip works therefore
-- depends on array order — the RPC's own test (T2) passed only because it
-- swapped primary to a newly inserted city.
--
-- Fix: demote any other primary in a separate statement before the upsert.
-- Everything still runs in the function's single implicit transaction, so the
-- operation remains atomic; the demote is simply ordered ahead of the
-- promotion. Behavior contract is otherwise unchanged.
--
-- Paired rollback:
--   supabase/rollbacks/20260816002000_set_preferred_cities_demote_first_down.sql
--
-- Regression coverage: supabase/tests/set_preferred_cities.sql T7 flips the
-- primary between two existing rows with the new primary FIRST in the array.

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

  -- 1. Remove any cities the user no longer wants.
  DELETE FROM public.user_preferred_cities
  WHERE user_id = v_uid
    AND city_id <> ALL (p_city_ids);

  -- 2. Demote any other primary BEFORE the upsert. The
  --    user_preferred_cities_one_primary partial unique index is enforced per
  --    row (not at statement end), so promoting the new primary inside the
  --    upsert while the old primary row is still true raises 23505 whenever
  --    the new primary sorts first in p_city_ids.
  UPDATE public.user_preferred_cities
  SET is_primary = false
  WHERE user_id = v_uid
    AND is_primary
    AND city_id <> p_primary_city_id;

  -- 3. Upsert the desired set; at most one row (the chosen primary) inserts a
  --    new entry into the partial unique index.
  INSERT INTO public.user_preferred_cities (user_id, city_id, is_primary)
  SELECT v_uid, c.city_id, (c.city_id = p_primary_city_id)
  FROM unnest(p_city_ids) AS c(city_id)
  ON CONFLICT (user_id, city_id)
  DO UPDATE SET is_primary = excluded.is_primary;

  -- 4. Mirror the chosen primary into the single-city compatibility column.
  UPDATE public.user_profiles
  SET city_preference_id = p_primary_city_id
  WHERE id = v_uid;
END;
$$;

COMMENT ON FUNCTION public.set_preferred_cities(uuid[], uuid) IS
  'Atomically replaces the calling user''s public.user_preferred_cities rows '
  'with p_city_ids (is_primary set on p_primary_city_id) and mirrors '
  'public.user_profiles.city_preference_id to the chosen primary, in one '
  'transaction. Demotes any previous primary before the upsert because the '
  'one-primary partial unique index is enforced per row (20260816002000). '
  'SECURITY INVOKER so owner-only RLS applies. authenticated only.';
