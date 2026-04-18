/*
  # Require invites by default

  Closed beta should fail closed:

  - if app.settings.require_invite is unset, invite gating stays on
  - no ALTER DATABASE is required on hosted Supabase
*/

CREATE OR REPLACE FUNCTION public.invites_required()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(current_setting('app.settings.require_invite', true), 'true') = 'true';
$$;

COMMENT ON FUNCTION public.invites_required IS
  'Returns true when app.settings.require_invite is enabled. Defaults to true when unset.';

GRANT EXECUTE ON FUNCTION public.invites_required() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  invite_required boolean;
BEGIN
  invite_required :=
    COALESCE(current_setting('app.settings.require_invite', true), 'true') = 'true';

  INSERT INTO public.user_profiles (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    coalesce(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
  )
  ON CONFLICT (id) DO NOTHING;

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
    NEW.id,
    NOT invite_required,
    CASE WHEN invite_required THEN NULL ELSE now() END,
    NULL,
    NULL,
    now(),
    now()
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;
