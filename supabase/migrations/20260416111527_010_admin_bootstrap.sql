/*
  # Admin bootstrap for production

  Problem: `006_seed_admin_user.sql` is intentionally empty on remote. Seed data
  (seed.sql) only runs locally. That meant deploying to production left nobody
  able to approve events — the admin panel checks `user_profiles.role = 'admin'`
  but no row with that role exists.

  Solution: a `private.bootstrap_admin()` function that reads `app.settings.admin_email`
  and promotes the matching profile to admin. Idempotent — safe to re-run after
  the configured user actually signs up.

  ## Production setup

  In Supabase Studio → SQL Editor run once:

    ALTER DATABASE postgres SET app.settings.admin_email = 'you@example.com';

  Then after the admin signs up via the app (/sign-up), call:

    SELECT private.bootstrap_admin();

  Returns the number of profiles promoted (0 or 1).
*/

CREATE OR REPLACE FUNCTION private.bootstrap_admin()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  configured_email text;
  promoted_count int := 0;
BEGIN
  BEGIN
    configured_email := current_setting('app.settings.admin_email', true);
  EXCEPTION WHEN undefined_object THEN
    configured_email := NULL;
  END;

  IF configured_email IS NULL OR configured_email = '' THEN
    RAISE NOTICE 'app.settings.admin_email is not configured — skipping admin bootstrap.';
    RETURN 0;
  END IF;

  UPDATE public.user_profiles
  SET role = 'admin', updated_at = now()
  WHERE lower(email) = lower(configured_email)
    AND role <> 'admin';

  GET DIAGNOSTICS promoted_count = ROW_COUNT;

  IF promoted_count > 0 THEN
    RAISE NOTICE 'Promoted % profile(s) matching % to admin.', promoted_count, configured_email;
  ELSE
    RAISE NOTICE 'No profile matching % to promote (user may not have signed up yet).', configured_email;
  END IF;

  RETURN promoted_count;
END;
$$;

COMMENT ON FUNCTION private.bootstrap_admin IS
  'Promotes the user matching app.settings.admin_email to admin. Idempotent. Run after configured user signs up.';

-- Only postgres (superuser) and service_role can invoke this function.
-- Admins must use Supabase Studio SQL Editor (which runs as postgres) to bootstrap.
REVOKE ALL ON FUNCTION private.bootstrap_admin FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.bootstrap_admin TO postgres, service_role;

-- Best-effort run at migration time — will no-op if setting isn't configured yet
-- or if the user hasn't signed up. Real bootstrap happens when admin calls this
-- from SQL editor after signing up.
DO $$
BEGIN
  PERFORM private.bootstrap_admin();
END;
$$;
