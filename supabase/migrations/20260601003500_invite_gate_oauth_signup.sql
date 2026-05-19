-- Closed-beta hardening: block new Google/Apple auth users unless an invite
-- claim already exists for the OAuth email.
--
-- This is intentionally OAuth-scoped so local seed and the existing email
-- signup path keep their current behavior. Email-created users still receive
-- disabled user_access when app.settings.require_invite is true; OAuth-created
-- users without a pending claim are rejected before public profile/access rows
-- are created.

BEGIN;

CREATE OR REPLACE FUNCTION private.enforce_invited_oauth_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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

REVOKE ALL ON FUNCTION private.enforce_invited_oauth_signup() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS enforce_invited_oauth_signup ON auth.users;
CREATE TRIGGER enforce_invited_oauth_signup
  BEFORE INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION private.enforce_invited_oauth_signup();

COMMENT ON FUNCTION private.enforce_invited_oauth_signup() IS
  'Blocks new Google/Apple auth.users rows while invite gating is enabled unless a live pending_invite_claims row exists for the OAuth email.';

COMMIT;
