-- Rollback for 20260601015000_fix_invite_gate_single_source.sql
-- 015000 routed two functions through private.invites_required() (single source of truth):
--   * public.handle_new_user()
--   * private.enforce_invited_oauth_signup()
-- Neither was modified by 012000-014000, so the state immediately before 015000 was each function's
-- baseline definition (both read the app.settings.require_invite GUC directly, default 'true').
-- Bodies restored verbatim from:
--   public.handle_new_user                -> 20260601000000_schema_baseline.sql:3646-3691
--   private.enforce_invited_oauth_signup  -> 20260601000000_schema_baseline.sql:2604-2667
-- CREATE OR REPLACE preserves owner, grants, and the attached triggers
-- (on_auth_user_created; enforce_invited_oauth_signup), symmetric with the bare CREATE OR REPLACE in UP.
--
-- NOTE: after this rollback, with the GUC unset both functions revert to gate-ON (default 'true'),
-- matching pre-015000 / baseline semantics.

BEGIN;

CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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
  v_invite_required :=
    lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'true')))
      IN ('true', 't', '1', 'yes');

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

COMMIT;
