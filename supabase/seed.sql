/*
  # Seed Local Admin User

  Creates a deterministic local development admin account that can sign in
  through Supabase Auth and access the admin area immediately after `supabase db reset`.

  This file is referenced in config.toml [db.seed] and only runs locally —
  it is never pushed to remote via `supabase db push`.
*/

DO $$
DECLARE
  admin_user_id constant uuid := '11111111-1111-4111-8111-111111111111';
  admin_email constant text := 'admin@familyevents.local';
  admin_password constant text := 'Admin123!';
BEGIN
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    confirmation_token,
    recovery_token,
    email_change_token_new,
    email_change_token_current,
    reauthentication_token,
    phone_change_token,
    phone_change,
    email_change,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  VALUES (
    '00000000-0000-0000-0000-000000000000',
    admin_user_id,
    'authenticated',
    'authenticated',
    admin_email,
    extensions.crypt(admin_password, extensions.gen_salt('bf')),
    now(),
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('display_name', 'Local Admin'),
    now(),
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET
    email = excluded.email,
    encrypted_password = excluded.encrypted_password,
    email_confirmed_at = excluded.email_confirmed_at,
    confirmation_token = excluded.confirmation_token,
    recovery_token = excluded.recovery_token,
    email_change_token_new = excluded.email_change_token_new,
    email_change_token_current = excluded.email_change_token_current,
    reauthentication_token = excluded.reauthentication_token,
    phone_change_token = excluded.phone_change_token,
    phone_change = excluded.phone_change,
    email_change = excluded.email_change,
    raw_app_meta_data = excluded.raw_app_meta_data,
    raw_user_meta_data = excluded.raw_user_meta_data,
    updated_at = now();

  UPDATE auth.users
  SET
    confirmation_token = '',
    recovery_token = '',
    email_change_token_new = '',
    email_change_token_current = '',
    reauthentication_token = '',
    phone_change_token = '',
    phone_change = '',
    email_change = '',
    updated_at = now()
  WHERE id = admin_user_id;

  INSERT INTO auth.identities (
    user_id,
    provider_id,
    identity_data,
    provider,
    last_sign_in_at,
    created_at,
    updated_at
  )
  VALUES (
    admin_user_id,
    admin_email,
    jsonb_build_object(
      'sub', admin_user_id::text,
      'email', admin_email,
      'email_verified', true
    ),
    'email',
    now(),
    now(),
    now()
  )
  ON CONFLICT (provider_id, provider) DO UPDATE
  SET
    user_id = excluded.user_id,
    identity_data = excluded.identity_data,
    last_sign_in_at = excluded.last_sign_in_at,
    updated_at = now();

  INSERT INTO public.user_profiles (
    id,
    email,
    display_name,
    role
  )
  VALUES (
    admin_user_id,
    admin_email,
    'Local Admin',
    'admin'
  )
  ON CONFLICT (id) DO UPDATE
  SET
    email = excluded.email,
    display_name = excluded.display_name,
    role = excluded.role,
    updated_at = now();
END
$$;
