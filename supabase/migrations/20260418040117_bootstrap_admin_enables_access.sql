/*
  # Bootstrap admin enables access

  Gatekeeping changed admin eligibility:

  - private.is_admin() now requires role = admin and user_access.is_enabled = true
  - private.bootstrap_admin() only promoted the role

  Result:
  - seeded/local admin could remain disabled if seeded before setup-local flipped
    require_invite off
  - production bootstrap could create an admin that still could not use the app

  Fix:
  - bootstrap_admin now also enables user_access for the configured admin email
*/

CREATE OR REPLACE FUNCTION private.bootstrap_admin()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  configured_email text;
  target_user_id uuid;
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

  SELECT id
  INTO target_user_id
  FROM public.user_profiles
  WHERE lower(email) = lower(configured_email)
  LIMIT 1;

  IF target_user_id IS NULL THEN
    RAISE NOTICE 'No profile matching % to promote (user may not have signed up yet).', configured_email;
    RETURN 0;
  END IF;

  UPDATE public.user_profiles
  SET role = 'admin', updated_at = now()
  WHERE id = target_user_id
    AND role <> 'admin';

  GET DIAGNOSTICS promoted_count = ROW_COUNT;

  INSERT INTO public.user_access (
    user_id,
    is_enabled,
    enabled_at,
    disabled_at,
    disabled_reason,
    created_at,
    updated_at
  )
  VALUES (
    target_user_id,
    true,
    now(),
    NULL,
    NULL,
    now(),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET is_enabled = true,
        enabled_at = COALESCE(public.user_access.enabled_at, now()),
        disabled_at = NULL,
        disabled_reason = NULL,
        updated_at = now();

  IF promoted_count > 0 THEN
    RAISE NOTICE 'Promoted % profile(s) matching % to admin and enabled access.', promoted_count, configured_email;
  ELSE
    RAISE NOTICE 'Admin profile for % already existed; ensured access is enabled.', configured_email;
  END IF;

  RETURN 1;
END;
$$;
