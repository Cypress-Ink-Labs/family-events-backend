/*
  # Family Events Platform — Functions & Triggers

  All functions and triggers in their final form. Private helpers first,
  then public ones that depend on them.
*/

-- =============================================
-- private.is_admin()
-- Expiry-aware admin check used by all RLS policies.
-- =============================================
CREATE OR REPLACE FUNCTION private.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    JOIN public.user_access ua ON ua.user_id = up.id
    WHERE up.id = auth.uid()
      AND up.role = 'admin'
      AND ua.is_enabled = true
      AND (ua.access_expires_at IS NULL OR ua.access_expires_at > now())
  );
$$;

-- =============================================
-- private.has_enabled_access()
-- =============================================
CREATE OR REPLACE FUNCTION private.has_enabled_access()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_access ua
    WHERE ua.user_id = auth.uid()
      AND ua.is_enabled = true
      AND (ua.access_expires_at IS NULL OR ua.access_expires_at > now())
  );
$$;

-- =============================================
-- private.current_profile_role()
-- Used by the user_profiles UPDATE policy WITH CHECK to prevent
-- self-escalation without triggering RLS recursion.
-- =============================================
CREATE OR REPLACE FUNCTION private.current_profile_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT role FROM public.user_profiles WHERE id = auth.uid();
$$;

-- =============================================
-- private.bootstrap_admin()
-- Promotes the user matching app.settings.admin_email to admin
-- and ensures their user_access row is enabled.
-- Run from SQL editor after the configured user signs up.
-- =============================================
CREATE OR REPLACE FUNCTION private.bootstrap_admin()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  configured_email text;
  target_user_id   uuid;
  promoted_count   int := 0;
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

  SELECT id INTO target_user_id
  FROM public.user_profiles
  WHERE lower(email) = lower(configured_email)
  LIMIT 1;

  IF target_user_id IS NULL THEN
    RAISE NOTICE 'No profile matching % to promote (user may not have signed up yet).', configured_email;
    RETURN 0;
  END IF;

  UPDATE public.user_profiles
  SET role = 'admin', updated_at = now()
  WHERE id = target_user_id AND role <> 'admin';

  GET DIAGNOSTICS promoted_count = ROW_COUNT;

  INSERT INTO public.user_access (
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (target_user_id, true, now(), NULL, NULL, now(), now())
  ON CONFLICT (user_id) DO UPDATE
    SET is_enabled       = true,
        enabled_at       = COALESCE(public.user_access.enabled_at, now()),
        disabled_at      = NULL,
        disabled_reason  = NULL,
        updated_at       = now();

  IF promoted_count > 0 THEN
    RAISE NOTICE 'Promoted % profile(s) matching % to admin and enabled access.', promoted_count, configured_email;
  ELSE
    RAISE NOTICE 'Admin profile for % already existed; ensured access is enabled.', configured_email;
  END IF;

  RETURN 1;
END;
$$;

REVOKE ALL ON FUNCTION private.bootstrap_admin FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.bootstrap_admin TO postgres, service_role;

-- =============================================
-- public.is_enabled_user()
-- Readable wrapper for client code.
-- =============================================
CREATE OR REPLACE FUNCTION public.is_enabled_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.has_enabled_access();
$$;

REVOKE ALL ON FUNCTION public.is_enabled_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_enabled_user() TO authenticated;

-- =============================================
-- public.invites_required()
-- Defaults to true (fail-closed) when setting is unset.
-- =============================================
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
  'Returns true when invite gating is on. Defaults to true when app.settings.require_invite is unset.';

GRANT EXECUTE ON FUNCTION public.invites_required() TO anon, authenticated;

-- =============================================
-- public.handle_new_user() — auth trigger
-- Creates user_profiles + user_access on signup.
-- =============================================
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
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (
    NEW.id,
    NOT invite_required,
    CASE WHEN invite_required THEN NULL ELSE now() END,
    NULL, NULL, now(), now()
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =============================================
-- public.update_event_search_vector() — events trigger
-- =============================================
CREATE OR REPLACE FUNCTION public.update_event_search_vector()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.search_vector := to_tsvector('english',
    coalesce(NEW.title, '') || ' ' ||
    coalesce(NEW.description, '') || ' ' ||
    coalesce(NEW.venue_name, '') || ' ' ||
    coalesce(NEW.address, '')
  );
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS events_search_vector_trigger ON public.events;
CREATE TRIGGER events_search_vector_trigger
  BEFORE INSERT OR UPDATE ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.update_event_search_vector();

-- =============================================
-- public.invoke_scrape_source(uuid)
-- Called by the pg_cron sweep; posts to the scrape-source edge function.
-- =============================================
CREATE OR REPLACE FUNCTION public.invoke_scrape_source(source_uuid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  supabase_url    text := current_setting('app.settings.supabase_url', true);
  service_role_key text := current_setting('app.settings.service_role_key', true);
BEGIN
  IF supabase_url IS NULL OR service_role_key IS NULL THEN
    RAISE NOTICE 'Skipping scrape: app.settings.supabase_url/service_role_key not set';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := supabase_url || '/functions/v1/scrape-source',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
    ),
    body    := jsonb_build_object('source_id', source_uuid)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invoke_scrape_source(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invoke_scrape_source(uuid) TO postgres, service_role;

-- =============================================
-- public.run_due_source_scrapes()
-- Invoked hourly by pg_cron.
-- =============================================
CREATE OR REPLACE FUNCTION public.run_due_source_scrapes()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  source_row record;
BEGIN
  FOR source_row IN
    SELECT id
    FROM public.event_sources
    WHERE is_active = true
      AND (
        last_scraped_at IS NULL
        OR last_scraped_at + make_interval(hours => scrape_interval_hours) <= now()
      )
  LOOP
    PERFORM public.invoke_scrape_source(source_row.id);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.run_due_source_scrapes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.run_due_source_scrapes() TO postgres, service_role;

DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('scrape-due-sources-hourly');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  PERFORM cron.schedule(
    'scrape-due-sources-hourly',
    '0 * * * *',
    $sql$SELECT public.run_due_source_scrapes();$sql$
  );
END
$$;

-- =============================================
-- public.redeem_invite(text)
-- =============================================
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  rows_updated int;
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    RETURN false;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE code = btrim(p_code)
    AND used_count < max_uses
    AND (expires_at IS NULL OR expires_at > now());

  GET DIAGNOSTICS rows_updated = ROW_COUNT;
  RETURN rows_updated > 0;
END;
$$;

-- redeem_invite(text) is intentionally not granted to anon/authenticated.
-- The canonical signup flow uses redeem_invite_for_email + claim_pending_invite_access
-- which is idempotent across retries. Leaving redeem_invite(text) callable from the
-- client would let anyone burn invite capacity without ever creating a claim,
-- because it bumps used_count without parking a pending claim.
REVOKE ALL ON FUNCTION public.redeem_invite(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(text) TO postgres, service_role;

-- =============================================
-- public.redeem_invite_for_email(text, text)
-- Consumes an invite code and parks a pending claim for the email.
-- =============================================
CREATE OR REPLACE FUNCTION public.redeem_invite_for_email(p_code text, p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  canonical_email text;
  canonical_code  text;
  existing_code   text;
  rows_updated    int;
BEGIN
  canonical_email := lower(btrim(p_email));
  canonical_code  := btrim(coalesce(p_code, ''));

  IF canonical_code = '' OR canonical_email = '' THEN
    RETURN false;
  END IF;

  -- Idempotent re-submit of the same code → no work, no capacity burn.
  IF EXISTS (
    SELECT 1
    FROM public.pending_invite_claims
    WHERE email = canonical_email
      AND invite_code = canonical_code
      AND claimed_by IS NULL
      AND expires_at > now()
  ) THEN
    RETURN true;
  END IF;

  -- If an unclaimed pending claim exists for this email with a DIFFERENT
  -- code, refund that prior code's used_count before consuming the new one.
  -- Without this refund, a user who pastes the wrong code first burns one
  -- use on every retry. (Already-claimed or expired claims are not refunded.)
  SELECT invite_code INTO existing_code
  FROM public.pending_invite_claims
  WHERE email = canonical_email
    AND claimed_by IS NULL
    AND expires_at > now()
  LIMIT 1;

  IF existing_code IS NOT NULL AND existing_code <> canonical_code THEN
    UPDATE public.invite_codes
    SET used_count = GREATEST(used_count - 1, 0)
    WHERE code = existing_code;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE code = canonical_code
    AND used_count < max_uses
    AND (expires_at IS NULL OR expires_at > now());

  GET DIAGNOSTICS rows_updated = ROW_COUNT;
  IF rows_updated = 0 THEN
    RETURN false;
  END IF;

  INSERT INTO public.pending_invite_claims (email, invite_code, expires_at, claimed_by, claimed_at, created_at)
  VALUES (canonical_email, canonical_code, now() + interval '2 hours', NULL, NULL, now())
  ON CONFLICT (email) DO UPDATE
    SET invite_code = excluded.invite_code,
        expires_at  = excluded.expires_at,
        claimed_by  = NULL,
        claimed_at  = NULL,
        created_at  = now();

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.redeem_invite_for_email(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite_for_email(text, text) TO anon, authenticated;

-- =============================================
-- public.claim_pending_invite_access()
-- Called after sign-in to enable access for a redeemed invite email.
-- =============================================
CREATE OR REPLACE FUNCTION public.claim_pending_invite_access()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_user_id  uuid;
  canonical_email  text;
  claim_exists     boolean;
BEGIN
  current_user_id := auth.uid();
  canonical_email := lower(coalesce(auth.jwt() ->> 'email', ''));

  IF current_user_id IS NULL OR canonical_email = '' THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.pending_invite_claims
    WHERE email = canonical_email AND claimed_by IS NULL AND expires_at > now()
  ) INTO claim_exists;

  IF NOT claim_exists THEN
    RETURN false;
  END IF;

  INSERT INTO public.user_access (
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (current_user_id, true, now(), NULL, NULL, now(), now())
  ON CONFLICT (user_id) DO UPDATE
    SET is_enabled      = true,
        enabled_at      = COALESCE(public.user_access.enabled_at, now()),
        disabled_at     = NULL,
        disabled_reason = NULL,
        updated_at      = now();

  UPDATE public.pending_invite_claims
  SET claimed_by = current_user_id, claimed_at = now()
  WHERE email = canonical_email AND claimed_by IS NULL AND expires_at > now();

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_pending_invite_access() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_pending_invite_access() TO authenticated;

-- =============================================
-- public.prevent_role_change() — user_profiles BEFORE UPDATE trigger
-- Defense-in-depth: prevents self-escalation of role column.
-- Server-side callers (NULL auth.uid()) are trusted.
-- =============================================
CREATE OR REPLACE FUNCTION public.prevent_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    IF auth.uid() IS NULL THEN
      RETURN NEW;
    END IF;
    IF NOT private.is_admin() THEN
      RAISE EXCEPTION 'Only admins can change user_profiles.role' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.prevent_role_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS prevent_role_change_on_profile ON public.user_profiles;
CREATE TRIGGER prevent_role_change_on_profile
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.prevent_role_change();

-- =============================================
-- public.reset_comment_approval_for_non_admin() — comments BEFORE UPDATE trigger
-- Silently reverts is_approved changes made by non-admins.
-- =============================================
CREATE OR REPLACE FUNCTION public.reset_comment_approval_for_non_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.is_approved IS DISTINCT FROM OLD.is_approved THEN
    IF auth.uid() IS NOT NULL AND NOT private.is_admin() THEN
      NEW.is_approved := OLD.is_approved;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_comment_approval_for_non_admin() FROM PUBLIC;

DROP TRIGGER IF EXISTS reset_comment_approval_on_update ON public.comments;
CREATE TRIGGER reset_comment_approval_on_update
  BEFORE UPDATE ON public.comments
  FOR EACH ROW EXECUTE FUNCTION public.reset_comment_approval_for_non_admin();

-- =============================================
-- Column-level privilege hardening
-- Prevents PostgREST PATCH from updating user_profiles.role.
-- =============================================
REVOKE UPDATE ON public.user_profiles FROM authenticated;
REVOKE UPDATE ON public.user_profiles FROM anon;
GRANT UPDATE (email, display_name, avatar_url, city_preference_id, child_name, child_age, updated_at)
  ON public.user_profiles TO authenticated;

-- Best-effort admin bootstrap (no-op when setting not configured)
DO $$
BEGIN
  PERFORM private.bootstrap_admin();
END;
$$;
