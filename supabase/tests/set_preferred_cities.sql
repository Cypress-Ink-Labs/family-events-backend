/*
  # CIL-187 — set_preferred_cities RPC behavior + RLS

  Exercises public.set_preferred_cities(p_city_ids uuid[], p_primary_city_id uuid),
  the atomic preferred-cities primary-swap RPC (migration 20260620050000).

  Asserts, all inside one rolled-back transaction:
    - Happy path: replaces the caller's user_preferred_cities with the given set,
      marks exactly the chosen primary, and mirrors user_profiles.city_preference_id.
    - Primary swap + set change: re-calling flips is_primary to a new city and
      drops de-selected cities without violating user_preferred_cities_one_primary.
    - Guard: empty p_city_ids raises and changes nothing.
    - Guard: p_primary_city_id not in p_city_ids raises and changes nothing.
    - Guard: no authenticated user (auth.uid() NULL) raises.
    - RLS isolation: a second user's rows are never touched.

  The RPC is SECURITY INVOKER, so calls run under the `authenticated` role with
  request.jwt.claim.sub set (owner-only RLS applies). Assertions read the tables
  as the postgres superuser. Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 -f supabase/tests/set_preferred_cities.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixture: two users (u1 under test, u2 for isolation) and three cities.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('u1',     gen_random_uuid()::text),
  ('u2',     gen_random_uuid()::text),
  ('city_a', gen_random_uuid()::text),
  ('city_b', gen_random_uuid()::text),
  ('city_c', gen_random_uuid()::text);

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT (v)::uuid, k || '-cil187@test.local', 'authenticated', 'authenticated', now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k IN ('u1', 'u2');

-- handle_new_user auto-creates user_profiles; upsert to pin city_preference_id NULL.
INSERT INTO public.user_profiles (id, email, display_name, role, city_preference_id)
SELECT (v)::uuid, k || '-cil187@test.local', 'CIL187 ' || k, 'user', NULL
FROM _fx WHERE k IN ('u1', 'u2')
ON CONFLICT (id) DO UPDATE SET city_preference_id = NULL, updated_at = now();

INSERT INTO public.cities (id, name, slug, is_active)
SELECT (v)::uuid, 'CIL187 ' || k, 'cil187-' || substr(v, 1, 8), true
FROM _fx WHERE k IN ('city_a', 'city_b', 'city_c');

-- Seed u2 with a single primary city to assert cross-user isolation later.
INSERT INTO public.user_preferred_cities (user_id, city_id, is_primary)
SELECT (SELECT (v)::uuid FROM _fx WHERE k='u2'),
       (SELECT (v)::uuid FROM _fx WHERE k='city_b'),
       true;

-- -----------------------------------------------------------------------------
-- T1 Happy path: u1 selects [A, B], primary A.
-- -----------------------------------------------------------------------------
DO $$
DECLARE u1 uuid; a uuid; b uuid;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  SELECT (v)::uuid INTO a  FROM _fx WHERE k='city_a';
  SELECT (v)::uuid INTO b  FROM _fx WHERE k='city_b';

  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', u1::text, true);
  PERFORM public.set_preferred_cities(ARRAY[a, b]::uuid[], a);
  RESET role;
END $$;

DO $$
DECLARE u1 uuid; a uuid; n int; prim int; mirror uuid;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  SELECT (v)::uuid INTO a  FROM _fx WHERE k='city_a';

  SELECT count(*) INTO n FROM public.user_preferred_cities WHERE user_id = u1;
  IF n <> 2 THEN RAISE EXCEPTION 'T1_FAIL: expected 2 rows, got %', n; END IF;

  SELECT count(*) INTO prim FROM public.user_preferred_cities WHERE user_id = u1 AND is_primary;
  IF prim <> 1 THEN RAISE EXCEPTION 'T1_FAIL: expected exactly 1 primary, got %', prim; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.user_preferred_cities WHERE user_id=u1 AND city_id=a AND is_primary
  ) THEN RAISE EXCEPTION 'T1_FAIL: city_a should be the primary'; END IF;

  SELECT city_preference_id INTO mirror FROM public.user_profiles WHERE id = u1;
  IF mirror IS DISTINCT FROM a THEN
    RAISE EXCEPTION 'T1_FAIL: profile mirror % <> city_a (%)', mirror, a;
  END IF;

  RAISE NOTICE 'T1_OK: happy path — 2 rows, primary=city_a, profile mirror set.';
END $$;

-- -----------------------------------------------------------------------------
-- T2 Primary swap + set change: u1 -> [A, C], primary C (drops B, moves primary).
-- -----------------------------------------------------------------------------
DO $$
DECLARE u1 uuid; a uuid; c uuid;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  SELECT (v)::uuid INTO a  FROM _fx WHERE k='city_a';
  SELECT (v)::uuid INTO c  FROM _fx WHERE k='city_c';

  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', u1::text, true);
  PERFORM public.set_preferred_cities(ARRAY[a, c]::uuid[], c);
  RESET role;
END $$;

DO $$
DECLARE u1 uuid; a uuid; b uuid; c uuid; n int; prim int; mirror uuid;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  SELECT (v)::uuid INTO a  FROM _fx WHERE k='city_a';
  SELECT (v)::uuid INTO b  FROM _fx WHERE k='city_b';
  SELECT (v)::uuid INTO c  FROM _fx WHERE k='city_c';

  SELECT count(*) INTO n FROM public.user_preferred_cities WHERE user_id = u1;
  IF n <> 2 THEN RAISE EXCEPTION 'T2_FAIL: expected 2 rows, got %', n; END IF;

  IF EXISTS (SELECT 1 FROM public.user_preferred_cities WHERE user_id=u1 AND city_id=b) THEN
    RAISE EXCEPTION 'T2_FAIL: city_b should have been removed';
  END IF;

  SELECT count(*) INTO prim FROM public.user_preferred_cities WHERE user_id = u1 AND is_primary;
  IF prim <> 1 THEN RAISE EXCEPTION 'T2_FAIL: expected exactly 1 primary, got %', prim; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.user_preferred_cities WHERE user_id=u1 AND city_id=c AND is_primary
  ) THEN RAISE EXCEPTION 'T2_FAIL: city_c should be the new primary'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.user_preferred_cities WHERE user_id=u1 AND city_id=a AND is_primary
  ) THEN RAISE EXCEPTION 'T2_FAIL: city_a should no longer be primary'; END IF;

  SELECT city_preference_id INTO mirror FROM public.user_profiles WHERE id = u1;
  IF mirror IS DISTINCT FROM c THEN
    RAISE EXCEPTION 'T2_FAIL: profile mirror % <> city_c (%)', mirror, c;
  END IF;

  RAISE NOTICE 'T2_OK: swap — city_b dropped, primary moved to city_c, mirror updated.';
END $$;

-- -----------------------------------------------------------------------------
-- T3 Guard: empty p_city_ids raises and leaves u1 state ([A,C] primary C) intact.
-- -----------------------------------------------------------------------------
DO $$
DECLARE u1 uuid; a uuid; threw boolean := false;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  SELECT (v)::uuid INTO a  FROM _fx WHERE k='city_a';

  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', u1::text, true);
  BEGIN
    PERFORM public.set_preferred_cities(ARRAY[]::uuid[], a);
  EXCEPTION WHEN OTHERS THEN threw := true;
  END;
  RESET role;

  IF NOT threw THEN RAISE EXCEPTION 'T3_FAIL: empty p_city_ids did not raise'; END IF;
  RAISE NOTICE 'T3_OK: empty p_city_ids rejected.';
END $$;

-- -----------------------------------------------------------------------------
-- T4 Guard: p_primary_city_id not in p_city_ids raises and changes nothing.
-- -----------------------------------------------------------------------------
DO $$
DECLARE u1 uuid; a uuid; b uuid; c uuid; threw boolean := false;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  SELECT (v)::uuid INTO a  FROM _fx WHERE k='city_a';
  SELECT (v)::uuid INTO b  FROM _fx WHERE k='city_b';
  SELECT (v)::uuid INTO c  FROM _fx WHERE k='city_c';

  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', u1::text, true);
  BEGIN
    PERFORM public.set_preferred_cities(ARRAY[a, c]::uuid[], b); -- b not in [a,c]
  EXCEPTION WHEN OTHERS THEN threw := true;
  END;
  RESET role;

  IF NOT threw THEN RAISE EXCEPTION 'T4_FAIL: primary-not-in-list did not raise'; END IF;
  RAISE NOTICE 'T4_OK: p_primary_city_id outside p_city_ids rejected.';
END $$;

-- State after the two guards must be unchanged from T2: [A(not), C(primary)], mirror C.
DO $$
DECLARE u1 uuid; c uuid; n int; prim int; mirror uuid;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  SELECT (v)::uuid INTO c  FROM _fx WHERE k='city_c';

  SELECT count(*) INTO n FROM public.user_preferred_cities WHERE user_id = u1;
  SELECT count(*) INTO prim FROM public.user_preferred_cities WHERE user_id = u1 AND is_primary;
  SELECT city_preference_id INTO mirror FROM public.user_profiles WHERE id = u1;

  IF n <> 2 OR prim <> 1 OR mirror IS DISTINCT FROM c THEN
    RAISE EXCEPTION 'GUARD_NOOP_FAIL: state changed by a rejected call (rows=%, primary=%, mirror=%)', n, prim, mirror;
  END IF;
  RAISE NOTICE 'GUARD_NOOP_OK: rejected calls left u1 state untouched.';
END $$;

-- -----------------------------------------------------------------------------
-- T5 Guard: no authenticated user (auth.uid() NULL) raises.
-- -----------------------------------------------------------------------------
DO $$
DECLARE a uuid; threw boolean := false;
BEGIN
  SELECT (v)::uuid INTO a FROM _fx WHERE k='city_a';
  PERFORM set_config('request.jwt.claim.sub', '', true); -- no subject -> auth.uid() NULL
  BEGIN
    PERFORM public.set_preferred_cities(ARRAY[a]::uuid[], a);
  EXCEPTION WHEN OTHERS THEN threw := true;
  END;
  IF NOT threw THEN RAISE EXCEPTION 'T5_FAIL: NULL auth.uid() did not raise'; END IF;
  RAISE NOTICE 'T5_OK: unauthenticated call rejected.';
END $$;

-- -----------------------------------------------------------------------------
-- T6 RLS isolation: u2's seeded row is untouched by all of u1's operations.
-- -----------------------------------------------------------------------------
DO $$
DECLARE u2 uuid; b uuid; n int; mirror uuid;
BEGIN
  SELECT (v)::uuid INTO u2 FROM _fx WHERE k='u2';
  SELECT (v)::uuid INTO b  FROM _fx WHERE k='city_b';

  SELECT count(*) INTO n FROM public.user_preferred_cities WHERE user_id = u2;
  IF n <> 1 THEN RAISE EXCEPTION 'T6_FAIL: expected u2 to keep exactly 1 row, got %', n; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.user_preferred_cities WHERE user_id=u2 AND city_id=b AND is_primary
  ) THEN RAISE EXCEPTION 'T6_FAIL: u2 primary city_b row was altered'; END IF;

  SELECT city_preference_id INTO mirror FROM public.user_profiles WHERE id = u2;
  IF mirror IS NOT NULL THEN RAISE EXCEPTION 'T6_FAIL: u2 profile mirror was changed to %', mirror; END IF;

  RAISE NOTICE 'T6_OK: u2 rows + profile untouched by u1 operations.';
END $$;

ROLLBACK;

\echo 'set_preferred_cities: PASS'
