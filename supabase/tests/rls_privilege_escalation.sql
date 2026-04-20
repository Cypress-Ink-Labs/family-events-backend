/*
  # H1 — user_profiles.role privilege escalation is blocked

  Verifies defense-in-depth. Each of the three layers (REVOKE, trigger,
  WITH CHECK) is checked independently. Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/rls_privilege_escalation.sql

  Exit code 0 = all assertions passed.
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixture: a regular authenticated user with enabled access.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES ('uid', gen_random_uuid()::text);

-- Insert auth.users — handle_new_user trigger auto-creates matching
-- user_profiles and user_access rows, so we UPSERT on top.
INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT (v)::uuid, 'h1-user@test.local', 'authenticated', 'authenticated', now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k='uid';

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT (v)::uuid, 'h1-user@test.local', 'H1 User', 'user' FROM _fx WHERE k='uid'
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, updated_at = now();

INSERT INTO public.user_access (user_id, is_enabled, enabled_at)
SELECT (v)::uuid, true, now() FROM _fx WHERE k='uid'
ON CONFLICT (user_id) DO UPDATE SET is_enabled = true, enabled_at = now(), updated_at = now();

-- -----------------------------------------------------------------------------
-- Layer 1: column REVOKE — authenticated has no UPDATE on `role`.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  has_role_update boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.column_privileges
    WHERE grantee = 'authenticated'
      AND table_schema = 'public'
      AND table_name = 'user_profiles'
      AND column_name = 'role'
      AND privilege_type = 'UPDATE'
  ) INTO has_role_update;

  IF has_role_update THEN
    RAISE EXCEPTION 'LAYER1_FAIL: authenticated still holds UPDATE on user_profiles.role';
  END IF;
  RAISE NOTICE 'LAYER1_OK: REVOKE UPDATE (role) is in place for authenticated.';
END $$;

-- -----------------------------------------------------------------------------
-- Layer 2: BEFORE UPDATE trigger raises 42501 for non-admin role change.
-- Run as postgres but force the trigger to see a non-trusted current_user
-- by using SET LOCAL role authenticated; we must bypass the column GRANT by
-- temporarily re-granting, so that we isolate the trigger behavior.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  uid uuid;
  err_code text;
BEGIN
  SELECT (v)::uuid INTO uid FROM _fx WHERE k='uid';

  -- Temporarily re-grant so the column-level check doesn't mask the trigger.
  EXECUTE 'GRANT UPDATE (role) ON public.user_profiles TO authenticated';

  BEGIN
    SET LOCAL role authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    UPDATE public.user_profiles SET role = 'admin' WHERE id = uid;
    RESET role;
    RAISE EXCEPTION 'LAYER2_FAIL: trigger did not block role change';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET role;
      RAISE NOTICE 'LAYER2_OK: trigger raised insufficient_privilege as expected.';
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err_code = RETURNED_SQLSTATE;
      RESET role;
      IF err_code = '42501' THEN
        RAISE NOTICE 'LAYER2_OK: trigger raised 42501 as expected.';
      ELSE
        RAISE EXCEPTION 'LAYER2_FAIL: unexpected SQLSTATE % (%)', err_code, SQLERRM;
      END IF;
  END;

  -- Restore the revoke for layers 1/3 checks.
  EXECUTE 'REVOKE UPDATE (role) ON public.user_profiles FROM authenticated';
END $$;

-- -----------------------------------------------------------------------------
-- Layer 3: RLS WITH CHECK forbids role change even if column grant were open.
-- Drop the trigger for this test to isolate the WITH CHECK behavior.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  uid uuid;
  err_code text;
BEGIN
  SELECT (v)::uuid INTO uid FROM _fx WHERE k='uid';
  EXECUTE 'GRANT UPDATE (role) ON public.user_profiles TO authenticated';
  EXECUTE 'ALTER TABLE public.user_profiles DISABLE TRIGGER prevent_role_change_on_profile';

  BEGIN
    SET LOCAL role authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    UPDATE public.user_profiles SET role = 'admin' WHERE id = uid;
    RESET role;
    RAISE EXCEPTION 'LAYER3_FAIL: WITH CHECK did not block role change';
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err_code = RETURNED_SQLSTATE;
      RESET role;
      IF err_code IN ('42501', '23514') THEN
        RAISE NOTICE 'LAYER3_OK: WITH CHECK rejected role change (%).', err_code;
      ELSE
        RAISE EXCEPTION 'LAYER3_FAIL: unexpected SQLSTATE % (%)', err_code, SQLERRM;
      END IF;
  END;

  EXECUTE 'ALTER TABLE public.user_profiles ENABLE TRIGGER prevent_role_change_on_profile';
  EXECUTE 'REVOKE UPDATE (role) ON public.user_profiles FROM authenticated';
END $$;

-- -----------------------------------------------------------------------------
-- Final: confirm the row is still role='user'.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  SELECT role INTO r FROM public.user_profiles WHERE id = (SELECT (v)::uuid FROM _fx WHERE k='uid');
  IF r <> 'user' THEN
    RAISE EXCEPTION 'FINAL_FAIL: role was elevated to %, expected user', r;
  END IF;
  RAISE NOTICE 'FINAL_OK: role still user.';
END $$;

ROLLBACK;

\echo 'rls_privilege_escalation: PASS'
