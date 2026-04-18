/*
  # User access gatekeeping

  Adds a durable access-control layer for launch:

  - every auth user gets a user_access row
  - new users are disabled by default while invite gating is on
  - invited signups redeem a code for a specific email and later claim access
  - protected app data is no longer publicly readable
*/

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_access (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  is_enabled boolean NOT NULL DEFAULT false,
  enabled_at timestamptz,
  disabled_at timestamptz,
  disabled_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_access IS
  'App gatekeeping state. Users need an enabled row to access protected product routes and data.';

ALTER TABLE public.user_access ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.pending_invite_claims (
  email text PRIMARY KEY,
  invite_code text NOT NULL REFERENCES public.invite_codes(code) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '2 hours'),
  claimed_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  claimed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.pending_invite_claims IS
  'Temporary invite redemptions keyed by email until the signed-in auth user claims access.';

ALTER TABLE public.pending_invite_claims ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- Backfill existing users
-- -----------------------------------------------------------------------------
INSERT INTO public.user_access (
  user_id,
  is_enabled,
  enabled_at,
  disabled_at,
  disabled_reason,
  created_at,
  updated_at
)
SELECT
  up.id,
  true,
  COALESCE(up.created_at, now()),
  NULL,
  NULL,
  COALESCE(up.created_at, now()),
  now()
FROM public.user_profiles up
ON CONFLICT (user_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Access helpers
-- -----------------------------------------------------------------------------
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
  );
$$;

COMMENT ON FUNCTION private.has_enabled_access IS
  'Returns true when the current authenticated user has an enabled user_access row.';

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
  );
$$;

COMMENT ON FUNCTION private.is_admin IS
  'Returns true when the current user is an enabled admin.';

-- -----------------------------------------------------------------------------
-- Policies
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own access" ON public.user_access;
CREATE POLICY "Users can view own access"
  ON public.user_access FOR SELECT
  TO authenticated
  USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Admins can manage user access" ON public.user_access;
CREATE POLICY "Admins can manage user access"
  ON public.user_access FOR ALL
  TO authenticated
  USING ((select private.is_admin()))
  WITH CHECK ((select private.is_admin()));

-- No direct table access. Only SECURITY DEFINER functions use this table.
DROP POLICY IF EXISTS "No direct access to pending invite claims" ON public.pending_invite_claims;
CREATE POLICY "No direct access to pending invite claims"
  ON public.pending_invite_claims FOR ALL
  TO authenticated
  USING (false)
  WITH CHECK (false);

-- -----------------------------------------------------------------------------
-- Invite redemption + claim
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_invite_for_email(p_code text, p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  canonical_email text;
  rows_updated int;
BEGIN
  canonical_email := lower(btrim(p_email));

  IF p_code IS NULL OR btrim(p_code) = '' OR canonical_email IS NULL OR canonical_email = '' THEN
    RETURN false;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE code = btrim(p_code)
    AND used_count < max_uses
    AND (expires_at IS NULL OR expires_at > now());

  GET DIAGNOSTICS rows_updated = ROW_COUNT;
  IF rows_updated = 0 THEN
    RETURN false;
  END IF;

  INSERT INTO public.pending_invite_claims (
    email,
    invite_code,
    expires_at,
    claimed_by,
    claimed_at,
    created_at
  )
  VALUES (
    canonical_email,
    btrim(p_code),
    now() + interval '2 hours',
    NULL,
    NULL,
    now()
  )
  ON CONFLICT (email) DO UPDATE
    SET invite_code = excluded.invite_code,
        expires_at = excluded.expires_at,
        claimed_by = NULL,
        claimed_at = NULL,
        created_at = now();

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.redeem_invite_for_email IS
  'Consumes an invite code and reserves access for the supplied email until signup/signin claims it.';

REVOKE ALL ON FUNCTION public.redeem_invite_for_email(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite_for_email(text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.claim_pending_invite_access()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_user_id uuid;
  canonical_email text;
  claim_exists boolean;
BEGIN
  current_user_id := auth.uid();
  canonical_email := lower(coalesce(auth.jwt() ->> 'email', ''));

  IF current_user_id IS NULL OR canonical_email = '' THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.pending_invite_claims pic
    WHERE pic.email = canonical_email
      AND pic.claimed_by IS NULL
      AND pic.expires_at > now()
  )
  INTO claim_exists;

  IF NOT claim_exists THEN
    RETURN false;
  END IF;

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
    current_user_id,
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

  UPDATE public.pending_invite_claims
  SET claimed_by = current_user_id,
      claimed_at = now()
  WHERE email = canonical_email
    AND claimed_by IS NULL
    AND expires_at > now();

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.claim_pending_invite_access IS
  'Enables user_access for the current authenticated user when a pending invite claim exists for their email.';

REVOKE ALL ON FUNCTION public.claim_pending_invite_access() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_pending_invite_access() TO authenticated;

-- -----------------------------------------------------------------------------
-- New-user bootstrap
-- -----------------------------------------------------------------------------
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
    COALESCE(current_setting('app.settings.require_invite', true), 'false') = 'true';

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

-- -----------------------------------------------------------------------------
-- Gate product data behind enabled access
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Cities public read" ON public.cities;
CREATE POLICY "Enabled users can read cities"
  ON public.cities FOR SELECT
  TO authenticated
  USING ((select private.has_enabled_access()));

DROP POLICY IF EXISTS "Tags public read" ON public.tags;
CREATE POLICY "Enabled users can read tags"
  ON public.tags FOR SELECT
  TO authenticated
  USING ((select private.has_enabled_access()));

DROP POLICY IF EXISTS "Published events are public" ON public.events;
CREATE POLICY "Enabled users can read published events"
  ON public.events FOR SELECT
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND status = 'published'
  );

DROP POLICY IF EXISTS "Event tags public read" ON public.event_tags;
CREATE POLICY "Enabled users can read event tags"
  ON public.event_tags FOR SELECT
  TO authenticated
  USING ((select private.has_enabled_access()));

DROP POLICY IF EXISTS "Ratings are public" ON public.ratings;
CREATE POLICY "Enabled users can read ratings"
  ON public.ratings FOR SELECT
  TO authenticated
  USING ((select private.has_enabled_access()));

DROP POLICY IF EXISTS "Authenticated users can add ratings" ON public.ratings;
CREATE POLICY "Enabled users can add ratings"
  ON public.ratings FOR INSERT
  TO authenticated
  WITH CHECK (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can update own ratings" ON public.ratings;
CREATE POLICY "Enabled users can update own ratings"
  ON public.ratings FOR UPDATE
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  )
  WITH CHECK (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can delete own ratings" ON public.ratings;
CREATE POLICY "Enabled users can delete own ratings"
  ON public.ratings FOR DELETE
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Approved comments public read" ON public.comments;
CREATE POLICY "Enabled users can read approved comments"
  ON public.comments FOR SELECT
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND is_approved = true
  );

DROP POLICY IF EXISTS "Authenticated users can add comments" ON public.comments;
CREATE POLICY "Enabled users can add comments"
  ON public.comments FOR INSERT
  TO authenticated
  WITH CHECK (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can update own comments" ON public.comments;
CREATE POLICY "Enabled users can update own comments"
  ON public.comments FOR UPDATE
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  )
  WITH CHECK (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can delete own comments" ON public.comments;
CREATE POLICY "Enabled users can delete own comments"
  ON public.comments FOR DELETE
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can view own favorites" ON public.favorites;
CREATE POLICY "Enabled users can view own favorites"
  ON public.favorites FOR SELECT
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can add favorites" ON public.favorites;
CREATE POLICY "Enabled users can add favorites"
  ON public.favorites FOR INSERT
  TO authenticated
  WITH CHECK (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can delete own favorites" ON public.favorites;
CREATE POLICY "Enabled users can delete own favorites"
  ON public.favorites FOR DELETE
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can view own calendar events" ON public.user_calendar_events;
CREATE POLICY "Enabled users can view own calendar events"
  ON public.user_calendar_events FOR SELECT
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can add calendar events" ON public.user_calendar_events;
CREATE POLICY "Enabled users can add calendar events"
  ON public.user_calendar_events FOR INSERT
  TO authenticated
  WITH CHECK (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can delete own calendar events" ON public.user_calendar_events;
CREATE POLICY "Enabled users can delete own calendar events"
  ON public.user_calendar_events FOR DELETE
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can view own signals" ON public.recommendation_signals;
CREATE POLICY "Enabled users can view own signals"
  ON public.recommendation_signals FOR SELECT
  TO authenticated
  USING (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Users can insert signals" ON public.recommendation_signals;
CREATE POLICY "Enabled users can insert signals"
  ON public.recommendation_signals FOR INSERT
  TO authenticated
  WITH CHECK (
    (select private.has_enabled_access())
    AND (select auth.uid()) = user_id
  );

REVOKE SELECT ON public.event_rating_stats FROM anon;
REVOKE EXECUTE ON FUNCTION public.search_events(
  uuid,
  timestamptz,
  timestamptz,
  int,
  int,
  boolean,
  boolean,
  text[],
  text,
  text,
  int,
  int
) FROM anon;
