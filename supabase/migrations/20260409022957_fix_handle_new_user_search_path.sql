/*
  # Fix handle_new_user trigger function search_path

  ## Problem
  The handle_new_user() function is called from the auth.users table trigger.
  Without an explicit search_path, the function runs in the auth schema context
  and cannot resolve the user_profiles table in the public schema.

  ## Fix
  Recreate the function with SET search_path = public and use the fully qualified
  table name public.user_profiles to ensure it always resolves correctly.
*/

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    coalesce(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;
