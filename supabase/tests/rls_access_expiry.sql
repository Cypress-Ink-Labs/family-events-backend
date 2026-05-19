/*
  # H2 — access_expires_at is honored by is_enabled_user() and is_admin()

  Verifies that a user with `access_expires_at < now()` is blocked from
  enabled-user helpers, even when `is_enabled = true`. Also verifies an
  expired admin loses admin powers.

  Published event reads are intentionally public after the security-invoker
  public_events hardening migration, so this test only asserts the access
  helpers and user-scoped write/admin paths.

  Run with:

    psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
      -v ON_ERROR_STOP=1 \
      -f supabase/tests/rls_access_expiry.sql
*/

\set ON_ERROR_STOP on
\set VERBOSITY terse

BEGIN;

-- -----------------------------------------------------------------------------
-- Fixture: expired user and expired admin.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _fx (k text PRIMARY KEY, v text);
INSERT INTO _fx VALUES
  ('user_uid', gen_random_uuid()::text),
  ('admin_uid', gen_random_uuid()::text),
  ('event_id', gen_random_uuid()::text);

INSERT INTO auth.users (id, email, aud, role, email_confirmed_at, instance_id)
SELECT (v)::uuid,
       CASE k WHEN 'user_uid' THEN 'h2-user@test.local' ELSE 'h2-admin@test.local' END,
       'authenticated', 'authenticated', now(),
       '00000000-0000-0000-0000-000000000000'
FROM _fx WHERE k IN ('user_uid', 'admin_uid');

INSERT INTO public.user_profiles (id, email, display_name, role)
SELECT (v)::uuid,
       CASE k WHEN 'user_uid' THEN 'h2-user@test.local' ELSE 'h2-admin@test.local' END,
       CASE k WHEN 'user_uid' THEN 'H2 User' ELSE 'H2 Admin' END,
       CASE k WHEN 'user_uid' THEN 'user' ELSE 'admin' END
FROM _fx WHERE k IN ('user_uid', 'admin_uid')
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, updated_at = now();

INSERT INTO public.user_access (user_id, is_enabled, enabled_at, access_expires_at)
SELECT (v)::uuid, true, now() - interval '10 days', now() - interval '1 day'
FROM _fx WHERE k IN ('user_uid', 'admin_uid')
ON CONFLICT (user_id) DO UPDATE
  SET is_enabled = true,
      enabled_at = EXCLUDED.enabled_at,
      access_expires_at = EXCLUDED.access_expires_at,
      updated_at = now();

INSERT INTO public.events (id, title, start_datetime, status)
SELECT (v)::uuid, 'H2 Published Event', now() + interval '1 day', 'published'
FROM _fx WHERE k = 'event_id';

-- -----------------------------------------------------------------------------
-- Expired regular user: is_enabled_user() returns false.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  uid uuid;
  r boolean;
BEGIN
  SELECT (v)::uuid INTO uid FROM _fx WHERE k='user_uid';
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  SELECT public.is_enabled_user() INTO r;
  IF r IS NOT FALSE THEN
    RESET role;
    RAISE EXCEPTION 'USER_FAIL: expired user sees is_enabled_user()=%, expected false', r;
  END IF;
  RESET role;
  RAISE NOTICE 'USER_OK: expired user blocked by is_enabled_user().';
END $$;

-- -----------------------------------------------------------------------------
-- Expired user: published events remain readable via the public SELECT policy.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  uid uuid;
  n int;
BEGIN
  SELECT (v)::uuid INTO uid FROM _fx WHERE k='user_uid';
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  SELECT count(*) INTO n FROM public.events WHERE status = 'published';
  RESET role;
  IF n < 1 THEN
    RAISE EXCEPTION 'EVENTS_FAIL: expired user saw % published events, expected public read access', n;
  END IF;
  RAISE NOTICE 'EVENTS_OK: expired user keeps public published-event read access.';
END $$;

-- -----------------------------------------------------------------------------
-- Expired user: favorites INSERT blocked by WITH CHECK.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  uid uuid;
  eid uuid;
  err_code text;
BEGIN
  SELECT (v)::uuid INTO uid FROM _fx WHERE k='user_uid';
  SELECT (v)::uuid INTO eid FROM _fx WHERE k='event_id';

  BEGIN
    SET LOCAL role authenticated;
    PERFORM set_config('request.jwt.claim.sub', uid::text, true);
    INSERT INTO public.favorites (user_id, event_id) VALUES (uid, eid);
    RESET role;
    RAISE EXCEPTION 'FAV_FAIL: expired user was able to INSERT into favorites';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET role;
      RAISE NOTICE 'FAV_OK: expired user blocked from favorites INSERT.';
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err_code = RETURNED_SQLSTATE;
      RESET role;
      IF err_code IN ('42501', '23514') THEN
        RAISE NOTICE 'FAV_OK: expired user blocked from favorites INSERT (%).', err_code;
      ELSE
        RAISE EXCEPTION 'FAV_FAIL: unexpected SQLSTATE % (%)', err_code, SQLERRM;
      END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- Expired admin: is_admin() returns false — probe via the events SELECT
-- policy, which is the only path an admin would see drafts through.
-- -----------------------------------------------------------------------------
INSERT INTO public.events (id, title, start_datetime, status)
VALUES (gen_random_uuid(), 'H2 Draft Event', now() + interval '1 day', 'draft');

DO $$
DECLARE
  uid uuid;
  draft_visible boolean;
BEGIN
  SELECT (v)::uuid INTO uid FROM _fx WHERE k='admin_uid';
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  SELECT EXISTS (SELECT 1 FROM public.events WHERE status = 'draft') INTO draft_visible;
  RESET role;

  IF draft_visible THEN
    RAISE EXCEPTION 'ADMIN_FAIL: expired admin can still see draft events (is_admin should be false)';
  END IF;
  RAISE NOTICE 'ADMIN_OK: expired admin blocked from drafts (is_admin returns false).';
END $$;

ROLLBACK;

\echo 'rls_access_expiry: PASS'
