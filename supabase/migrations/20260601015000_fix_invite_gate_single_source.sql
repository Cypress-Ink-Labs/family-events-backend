-- =============================================================================
-- Migration: Invite gate single source of truth
-- =============================================================================
--
-- 20260601012000 / 20260601014000 changed private.invites_required() to default
-- FALSE (open registration) when app.settings.require_invite is unset, and
-- 20260601013000 cleared any GUC override.
--
-- BUT two functions still read the GUC directly with a hardcoded 'true' default,
-- so they never observed the flip:
--
--   * public.handle_new_user()              -> new accounts created DISABLED
--   * private.enforce_invited_oauth_signup() -> all Google/Apple signups blocked
--
-- This made "open registration" silently broken: every new email user landed
-- with user_access.is_enabled = false, and OAuth signups raised 'Invite required'
-- at the auth.users INSERT trigger.
--
-- Fix: route BOTH functions through private.invites_required() so the gate has a
-- single source of truth. Toggling the gate now only requires the GUC + that one
-- helper (see supabase/docs/INVITE_GATE.md).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- handle_new_user: use private.invites_required() instead of reading the GUC.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  invite_required boolean;
  v_username      text;
BEGIN
  invite_required := private.invites_required();

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

-- -----------------------------------------------------------------------------
-- enforce_invited_oauth_signup: use private.invites_required() for the gate flag.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "private"."enforce_invited_oauth_signup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_invite_required boolean;
  v_email text;
  v_primary_provider text;
  v_providers text[] := ARRAY[]::text[];
  v_is_oauth boolean;
  v_claim_exists boolean;
BEGIN
  v_invite_required := private.invites_required();

  IF NOT v_invite_required THEN
    RETURN NEW;
  END IF;

  v_primary_provider := lower(btrim(coalesce(NEW.raw_app_meta_data->>'provider', '')));

  SELECT coalesce(array_agg(lower(provider_value)), ARRAY[]::text[])
    INTO v_providers
  FROM jsonb_array_elements_text(coalesce(NEW.raw_app_meta_data->'providers', '[]'::jsonb))
       AS providers(provider_value);

  v_is_oauth :=
    v_primary_provider IN ('apple', 'google')
    OR v_providers && ARRAY['apple', 'google']::text[];

  IF NOT v_is_oauth THEN
    RETURN NEW;
  END IF;

  v_email := lower(btrim(coalesce(NEW.email, '')));

  IF v_email = '' THEN
    RAISE EXCEPTION 'Invite required'
      USING
        ERRCODE = 'P0001',
        DETAIL = 'OAuth signup requires a pending invite claim with a verified email.',
        HINT = 'Redeem an invite code for the OAuth email before creating the account.';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.pending_invite_claims
    WHERE email = v_email
      AND claimed_by IS NULL
      AND expires_at > now()
  ) INTO v_claim_exists;

  IF NOT v_claim_exists THEN
    RAISE EXCEPTION 'Invite required'
      USING
        ERRCODE = 'P0001',
        DETAIL = 'OAuth signup requires a pending invite claim.',
        HINT = 'Redeem an invite code for the OAuth email before creating the account.';
  END IF;

  RETURN NEW;
END;
$$;
