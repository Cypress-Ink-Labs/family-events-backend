/*
  # OAuth invite gate

  Verifies that Google/Apple-created auth.users rows cannot bypass the closed
  beta invite gate when app.settings.require_invite is enabled.

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/invite_gate_oauth_signup.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('blocked_google_uid', gen_random_uuid()::text),
  ('invited_google_uid', gen_random_uuid()::text),
  ('open_apple_uid', gen_random_uuid()::text),
  ('email_uid', gen_random_uuid()::text),
  ('invited_email', 'invited-oauth@test.local');

-- Closed beta enabled.
SELECT set_config('app.settings.require_invite', 'true', false);

-- -----------------------------------------------------------------------------
-- Uninvited Google signup is rejected before auth.users insert.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  uid uuid;
  err_code text;
  err_message text;
  row_count int;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'blocked_google_uid';

  BEGIN
    INSERT INTO auth.users (
      id,
      email,
      aud,
      role,
      email_confirmed_at,
      instance_id,
      raw_app_meta_data,
      raw_user_meta_data
    )
    VALUES (
      uid,
      'blocked-google@test.local',
      'authenticated',
      'authenticated',
      now(),
      '00000000-0000-0000-0000-000000000000',
      jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
      jsonb_build_object('display_name', 'Blocked Google')
    );

    RAISE EXCEPTION 'BLOCKED_GOOGLE_FAIL: uninvited Google signup was inserted';
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS
        err_code = RETURNED_SQLSTATE,
        err_message = MESSAGE_TEXT;

      IF err_message LIKE 'BLOCKED_GOOGLE_FAIL:%' THEN
        RAISE EXCEPTION '%', err_message;
      END IF;

      IF err_code <> 'P0001' THEN
        RAISE EXCEPTION 'BLOCKED_GOOGLE_FAIL: unexpected SQLSTATE % (%)', err_code, SQLERRM;
      END IF;
  END;

  SELECT count(*) INTO row_count FROM auth.users WHERE id = uid;
  IF row_count <> 0 THEN
    RAISE EXCEPTION 'BLOCKED_GOOGLE_FAIL: auth.users row exists after rejection';
  END IF;

  SELECT count(*) INTO row_count FROM public.user_profiles WHERE id = uid;
  IF row_count <> 0 THEN
    RAISE EXCEPTION 'BLOCKED_GOOGLE_FAIL: user_profiles row exists after rejection';
  END IF;

  SELECT count(*) INTO row_count FROM public.user_access WHERE user_id = uid;
  IF row_count <> 0 THEN
    RAISE EXCEPTION 'BLOCKED_GOOGLE_FAIL: user_access row exists after rejection';
  END IF;

  RAISE NOTICE 'BLOCKED_GOOGLE_OK: uninvited Google signup rejected cleanly.';
END $$;

-- -----------------------------------------------------------------------------
-- Invited Google signup is allowed when a live pending claim exists.
-- -----------------------------------------------------------------------------
INSERT INTO public.pending_invite_claims (
  email,
  invite_code,
  expires_at,
  claimed_by,
  claimed_at,
  created_at
)
SELECT
  v,
  repeat('a', 64),
  now() + interval '1 hour',
  NULL,
  NULL,
  now()
FROM _fx
WHERE k = 'invited_email'
ON CONFLICT (email) DO UPDATE
SET
  invite_code = excluded.invite_code,
  expires_at = excluded.expires_at,
  claimed_by = NULL,
  claimed_at = NULL,
  created_at = now();

DO $$
DECLARE
  uid uuid;
  invite_email text;
  access_enabled boolean;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'invited_google_uid';
  SELECT v INTO invite_email FROM _fx WHERE k = 'invited_email';

  INSERT INTO auth.users (
    id,
    email,
    aud,
    role,
    email_confirmed_at,
    instance_id,
    raw_app_meta_data,
    raw_user_meta_data
  )
  VALUES (
    uid,
    invite_email,
    'authenticated',
    'authenticated',
    now(),
    '00000000-0000-0000-0000-000000000000',
    jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
    jsonb_build_object('display_name', 'Invited Google')
  );

  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = uid) THEN
    RAISE EXCEPTION 'INVITED_GOOGLE_FAIL: auth.users row was not inserted';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.user_profiles
    WHERE id = uid
      AND user_profiles.email = invite_email
  ) THEN
    RAISE EXCEPTION 'INVITED_GOOGLE_FAIL: user profile was not provisioned';
  END IF;

  SELECT is_enabled INTO access_enabled
  FROM public.user_access
  WHERE user_id = uid;

  IF access_enabled IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'INVITED_GOOGLE_FAIL: access should remain disabled until claim_pending_invite_access, got %', access_enabled;
  END IF;

  RAISE NOTICE 'INVITED_GOOGLE_OK: invited Google signup inserted with disabled initial access.';
END $$;

-- -----------------------------------------------------------------------------
-- The existing claim_pending_invite_access path still enables invited OAuth users.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  uid uuid;
  invite_email text;
  claim_result boolean;
  access_enabled boolean;
  claimed_by_id uuid;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'invited_google_uid';
  SELECT v INTO invite_email FROM _fx WHERE k = 'invited_email';

  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', uid::text, 'email', invite_email, 'role', 'authenticated')::text,
    true
  );

  SELECT public.claim_pending_invite_access() INTO claim_result;
  RESET role;

  IF claim_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'CLAIM_FAIL: claim_pending_invite_access returned %, expected true', claim_result;
  END IF;

  SELECT is_enabled INTO access_enabled
  FROM public.user_access
  WHERE user_id = uid;

  IF access_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'CLAIM_FAIL: user_access.is_enabled=%, expected true', access_enabled;
  END IF;

  SELECT claimed_by INTO claimed_by_id
  FROM public.pending_invite_claims
  WHERE pending_invite_claims.email = invite_email;

  IF claimed_by_id IS DISTINCT FROM uid THEN
    RAISE EXCEPTION 'CLAIM_FAIL: pending claim claimed_by=%, expected %', claimed_by_id, uid;
  END IF;

  RAISE NOTICE 'CLAIM_OK: invited OAuth user can claim access after session sync.';
END $$;

-- -----------------------------------------------------------------------------
-- Open signup mode allows Apple OAuth without a pending invite claim.
-- -----------------------------------------------------------------------------
SELECT set_config('app.settings.require_invite', 'false', false);

DO $$
DECLARE
  uid uuid;
  access_enabled boolean;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'open_apple_uid';

  INSERT INTO auth.users (
    id,
    email,
    aud,
    role,
    email_confirmed_at,
    instance_id,
    raw_app_meta_data,
    raw_user_meta_data
  )
  VALUES (
    uid,
    'open-apple@test.local',
    'authenticated',
    'authenticated',
    now(),
    '00000000-0000-0000-0000-000000000000',
    jsonb_build_object('provider', 'apple', 'providers', jsonb_build_array('apple')),
    jsonb_build_object('display_name', 'Open Apple')
  );

  SELECT is_enabled INTO access_enabled
  FROM public.user_access
  WHERE user_id = uid;

  IF access_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'OPEN_APPLE_FAIL: open signup should create enabled access, got %', access_enabled;
  END IF;

  RAISE NOTICE 'OPEN_APPLE_OK: Apple signup allowed when invite gate is disabled.';
END $$;

-- -----------------------------------------------------------------------------
-- Email provider behavior remains unchanged under closed beta.
-- This preserves local seed and existing email signup semantics.
-- -----------------------------------------------------------------------------
SELECT set_config('app.settings.require_invite', 'true', false);

DO $$
DECLARE
  uid uuid;
  access_enabled boolean;
BEGIN
  SELECT v::uuid INTO uid FROM _fx WHERE k = 'email_uid';

  INSERT INTO auth.users (
    id,
    email,
    aud,
    role,
    email_confirmed_at,
    instance_id,
    raw_app_meta_data,
    raw_user_meta_data
  )
  VALUES (
    uid,
    'email-provider@test.local',
    'authenticated',
    'authenticated',
    now(),
    '00000000-0000-0000-0000-000000000000',
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('display_name', 'Email Provider')
  );

  SELECT is_enabled INTO access_enabled
  FROM public.user_access
  WHERE user_id = uid;

  IF access_enabled IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'EMAIL_PROVIDER_FAIL: closed beta email insert should keep disabled access, got %', access_enabled;
  END IF;

  RAISE NOTICE 'EMAIL_PROVIDER_OK: email provider behavior preserved.';
END $$;

-- -----------------------------------------------------------------------------
-- Default path (GUC absent): open registration.
-- This is the production default after 20260601012000/014000/015000 — the GUC is
-- unset, so private.invites_required() returns false and BOTH consumer functions
-- (handle_new_user, enforce_invited_oauth_signup) must treat the gate as OFF.
-- Regression guard for the half-applied invite-gate disable (audit H1): before
-- 20260601015000 these functions read the GUC directly with a hardcoded 'true'
-- default, so the absent-GUC path left new accounts disabled / OAuth blocked.
-- -----------------------------------------------------------------------------
SELECT set_config('app.settings.require_invite', NULL, false);

-- invites_required() must report the gate OFF when the GUC is absent.
DO $$
BEGIN
  IF private.invites_required() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'DEFAULT_GUC_FAIL: invites_required() should be false when GUC is unset, got %',
      private.invites_required();
  END IF;
END $$;

-- Email signup on the default path must land ENABLED.
DO $$
DECLARE
  uid uuid := gen_random_uuid();
  access_enabled boolean;
BEGIN
  INSERT INTO auth.users (
    id, email, aud, role, email_confirmed_at, instance_id,
    raw_app_meta_data, raw_user_meta_data
  )
  VALUES (
    uid, 'default-email@test.local', 'authenticated', 'authenticated', now(),
    '00000000-0000-0000-0000-000000000000',
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('display_name', 'Default Email')
  );

  SELECT is_enabled INTO access_enabled FROM public.user_access WHERE user_id = uid;

  IF access_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'DEFAULT_EMAIL_FAIL: absent-GUC email signup should be enabled, got %', access_enabled;
  END IF;

  RAISE NOTICE 'DEFAULT_EMAIL_OK: email signup enabled when invite GUC is unset.';
END $$;

-- Google OAuth signup with no pending claim must be allowed (not blocked) and ENABLED.
DO $$
DECLARE
  uid uuid := gen_random_uuid();
  access_enabled boolean;
BEGIN
  INSERT INTO auth.users (
    id, email, aud, role, email_confirmed_at, instance_id,
    raw_app_meta_data, raw_user_meta_data
  )
  VALUES (
    uid, 'default-google@test.local', 'authenticated', 'authenticated', now(),
    '00000000-0000-0000-0000-000000000000',
    jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
    jsonb_build_object('display_name', 'Default Google')
  );

  SELECT is_enabled INTO access_enabled FROM public.user_access WHERE user_id = uid;

  IF access_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'DEFAULT_GOOGLE_FAIL: absent-GUC OAuth signup should be enabled, got %', access_enabled;
  END IF;

  RAISE NOTICE 'DEFAULT_GOOGLE_OK: Google OAuth signup allowed + enabled when invite GUC is unset.';
END $$;

ROLLBACK;
