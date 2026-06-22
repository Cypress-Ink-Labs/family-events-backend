-- Migration: 20260620050000_set_preferred_cities_rpc.sql
--
-- CIL-187 (follow-up to CIL-168): atomic preferred-cities primary swap.
--
-- Introduces public.set_preferred_cities(p_city_ids uuid[], p_primary_city_id
-- uuid), an RPC callable via supabase-js .rpc() that, in a SINGLE transaction
-- (the implicit function-body transaction), replaces the calling user's rows in
-- public.user_preferred_cities AND keeps user_profiles.city_preference_id
-- mirrored to the chosen primary city. The frontend previously did this with a
-- non-atomic multi-statement client sequence (delete, then re-insert, then
-- update the profile), which could leave the two tables out of sync — or
-- transiently violate the user_preferred_cities_one_primary partial unique
-- index — if a statement failed mid-flight.
--
-- Design notes:
--   • SECURITY INVOKER: the function runs as the calling user so the existing
--     owner-only RLS on public.user_preferred_cities (user_id = auth.uid()) and
--     on public.user_profiles ("Users can update own profile…") continues to
--     apply. No elevated privileges are introduced.
--   • Set-based upsert: a single INSERT … SELECT unnest(…) … ON CONFLICT … DO
--     UPDATE flips is_primary for every requested city in one statement, so the
--     user_preferred_cities_one_primary index (UNIQUE … WHERE is_primary) is
--     never violated mid-operation — Postgres evaluates uniqueness once, at
--     statement end.
--   • SET search_path TO '' follows the pattern in
--     20260620030000_plan_events_for_user_range.sql and
--     20260618000000_find_similar_events_by_id_security_definer.sql; every
--     object reference below is schema-qualified.
--   • Grants: EXECUTE to authenticated only (no PUBLIC, no anon). auth.uid() is
--     non-NULL for these calls.
--
-- Paired rollback:
--   supabase/rollbacks/20260620050000_set_preferred_cities_rpc_down.sql
--
-- Manual verification steps (no live DB in CI):
--   1. Apply migration: pnpm run db:migrate
--   2. Confirm function exists:
--        SELECT proname FROM pg_proc
--        JOIN pg_namespace ns ON ns.oid = pronamespace
--        WHERE ns.nspname = 'public' AND proname = 'set_preferred_cities';
--   3. As an authenticated user, call:
--        SELECT public.set_preferred_cities(
--          ARRAY['<city-a>','<city-b>']::uuid[], '<city-a>'::uuid);
--      then verify:
--        • public.user_preferred_cities holds exactly those two rows for the
--          caller, with is_primary true only for <city-a>;
--        • public.user_profiles.city_preference_id = '<city-a>' for the caller.
--   4. Calling with p_primary_city_id NOT in p_city_ids, or with an empty
--      p_city_ids array, raises an exception and changes nothing.

-- ─── Function ────────────────────────────────────────────────────────────────

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

  -- 2. Upsert the desired set in a single set-based statement so the
  --    user_preferred_cities_one_primary partial unique index is only checked
  --    once, at statement end — never violated mid-operation.
  INSERT INTO public.user_preferred_cities (user_id, city_id, is_primary)
  SELECT v_uid, c.city_id, (c.city_id = p_primary_city_id)
  FROM unnest(p_city_ids) AS c(city_id)
  ON CONFLICT (user_id, city_id)
  DO UPDATE SET is_primary = excluded.is_primary;

  -- 3. Mirror the chosen primary into the single-city compatibility column.
  UPDATE public.user_profiles
  SET city_preference_id = p_primary_city_id
  WHERE id = v_uid;
END;
$$;

-- ─── Grants ────────────────────────────────────────────────────────────────
-- authenticated only: this RPC reads auth.uid() and operates on the caller's
-- own rows under existing owner-only RLS. No public or anon access.

REVOKE ALL ON FUNCTION public.set_preferred_cities(uuid[], uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.set_preferred_cities(uuid[], uuid) TO authenticated;

-- ─── Comment ─────────────────────────────────────────────────────────────────

COMMENT ON FUNCTION public.set_preferred_cities(uuid[], uuid) IS
  'Atomically replaces the calling user''s public.user_preferred_cities rows '
  'with p_city_ids (is_primary set on p_primary_city_id) and mirrors '
  'public.user_profiles.city_preference_id to the chosen primary, in one '
  'transaction. SECURITY INVOKER so owner-only RLS applies. authenticated only. '
  'Replaces the non-atomic multi-statement client sequence (CIL-187).';
