-- Dispatch a welcome email (family-events-welcome Resend template) when a new
-- auth user is created. The email fires via the same fire-and-forget pg_net
-- path used by invite notifications: handle_new_user → dispatch_email_notification
-- → notify-email edge function → Resend template API.
--
-- The dispatch is wrapped in an EXCEPTION block so a vault/network hiccup
-- never bubbles up to the caller — the user_profiles + user_access inserts
-- already happened before this runs.
--
-- Note: the welcome email fires for every new auth.users row, including users
-- who are still pending invite approval. This is intentional — the email
-- welcomes them to the platform regardless of access status.

BEGIN;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  invite_required boolean;
  v_username      text;
BEGIN
  invite_required :=
    COALESCE(current_setting('app.settings.require_invite', true), 'true') = 'true';

  v_username := coalesce(
    NEW.raw_user_meta_data->>'display_name',
    split_part(NEW.email, '@', 1)
  );

  INSERT INTO public.user_profiles (id, email, display_name)
  VALUES (NEW.id, NEW.email, v_username)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_access (
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (
    NEW.id,
    NOT invite_required,
    CASE WHEN invite_required THEN NULL ELSE now() END,
    NULL, NULL, now(), now()
  )
  ON CONFLICT (user_id) DO NOTHING;

  -- Fire welcome email async. Wrapped in EXCEPTION so a vault/secret hiccup
  -- never bubbles up — the profile + access rows are already committed above.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',     'welcome',
      'email',    NEW.email,
      'username', v_username
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch welcome email for %: %', NEW.email, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

-- Trigger already exists from 20260601000100_002_functions.sql;
-- DROP + CREATE ensures it points to the updated function body.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

COMMIT;
