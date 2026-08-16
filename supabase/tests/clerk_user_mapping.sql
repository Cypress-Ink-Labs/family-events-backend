/*
  # U19 — clerk_user_mapping table contract

  Asserts, all inside one rolled-back transaction:
    - A mapping row inserts for an existing auth user.
    - Injectivity both ways: duplicate clerk_user_id and duplicate
      supabase_uuid are rejected (PK / UNIQUE).
    - Shape checks: clerk_user_id must look like a Clerk ID ('user_…');
      role must be operator|member.
    - Browser roles are locked out: anon and authenticated get permission
      denied (RLS on with no policies + revoked table privileges).
    - Deleting the auth user cascades the mapping row.

  Run with:
    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 -f supabase/tests/clerk_user_mapping.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('u1', gen_random_uuid()::text),
  ('u2', gen_random_uuid()::text);

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT (v)::uuid, k || '-u19@test.local', 'authenticated', 'authenticated', now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx;

-- T1 Happy path insert.
DO $$
DECLARE u1 uuid;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  INSERT INTO public.clerk_user_mapping (clerk_user_id, supabase_uuid, email, role)
  VALUES ('user_u19test_1', u1, 'u1-u19@test.local', 'operator');
  RAISE NOTICE 'T1_OK: mapping row inserted.';
END $$;

-- T2 Duplicate clerk_user_id rejected (PK).
DO $$
DECLARE u2 uuid; threw boolean := false;
BEGIN
  SELECT (v)::uuid INTO u2 FROM _fx WHERE k='u2';
  BEGIN
    INSERT INTO public.clerk_user_mapping (clerk_user_id, supabase_uuid, email)
    VALUES ('user_u19test_1', u2, 'u2-u19@test.local');
  EXCEPTION WHEN unique_violation THEN threw := true;
  END;
  IF NOT threw THEN RAISE EXCEPTION 'T2_FAIL: duplicate clerk_user_id accepted'; END IF;
  RAISE NOTICE 'T2_OK: duplicate clerk_user_id rejected.';
END $$;

-- T3 Duplicate supabase_uuid rejected (UNIQUE): two Clerk accounts must never
-- share one uuid — the U7 pre-check depends on injectivity.
DO $$
DECLARE u1 uuid; threw boolean := false;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  BEGIN
    INSERT INTO public.clerk_user_mapping (clerk_user_id, supabase_uuid, email)
    VALUES ('user_u19test_2', u1, 'u1-u19@test.local');
  EXCEPTION WHEN unique_violation THEN threw := true;
  END;
  IF NOT threw THEN RAISE EXCEPTION 'T3_FAIL: duplicate supabase_uuid accepted'; END IF;
  RAISE NOTICE 'T3_OK: duplicate supabase_uuid rejected.';
END $$;

-- T4 Shape checks.
DO $$
DECLARE u2 uuid; threw boolean := false;
BEGIN
  SELECT (v)::uuid INTO u2 FROM _fx WHERE k='u2';
  BEGIN
    INSERT INTO public.clerk_user_mapping (clerk_user_id, supabase_uuid, email)
    VALUES ('not-a-clerk-id', u2, 'u2-u19@test.local');
  EXCEPTION WHEN check_violation THEN threw := true;
  END;
  IF NOT threw THEN RAISE EXCEPTION 'T4_FAIL: malformed clerk_user_id accepted'; END IF;

  threw := false;
  BEGIN
    INSERT INTO public.clerk_user_mapping (clerk_user_id, supabase_uuid, email, role)
    VALUES ('user_u19test_2', u2, 'u2-u19@test.local', 'admin');
  EXCEPTION WHEN check_violation THEN threw := true;
  END;
  IF NOT threw THEN RAISE EXCEPTION 'T4_FAIL: invalid role accepted'; END IF;
  RAISE NOTICE 'T4_OK: shape checks enforced.';
END $$;

-- T5 Browser roles locked out entirely.
DO $$
DECLARE threw boolean := false;
BEGIN
  SET LOCAL role anon;
  BEGIN
    PERFORM count(*) FROM public.clerk_user_mapping;
  EXCEPTION WHEN insufficient_privilege THEN threw := true;
  END;
  RESET role;
  IF NOT threw THEN RAISE EXCEPTION 'T5_FAIL: anon can read the mapping table'; END IF;

  threw := false;
  SET LOCAL role authenticated;
  BEGIN
    PERFORM count(*) FROM public.clerk_user_mapping;
  EXCEPTION WHEN insufficient_privilege THEN threw := true;
  END;
  RESET role;
  IF NOT threw THEN RAISE EXCEPTION 'T5_FAIL: authenticated can read the mapping table'; END IF;
  RAISE NOTICE 'T5_OK: anon/authenticated denied.';
END $$;

-- T6 Cascade: deleting the auth user removes the mapping row.
DO $$
DECLARE u1 uuid; n int;
BEGIN
  SELECT (v)::uuid INTO u1 FROM _fx WHERE k='u1';
  DELETE FROM auth.users WHERE id = u1;
  SELECT count(*) INTO n FROM public.clerk_user_mapping WHERE supabase_uuid = u1;
  IF n <> 0 THEN RAISE EXCEPTION 'T6_FAIL: mapping row survived auth user deletion'; END IF;
  RAISE NOTICE 'T6_OK: mapping row cascaded with auth user.';
END $$;

ROLLBACK;

\echo 'clerk_user_mapping: PASS'
