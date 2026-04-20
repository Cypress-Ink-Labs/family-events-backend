/*
  # RLS audit wave 1: is_enabled_user helper, privilege-escalation fix, anon read

  Implements the high-severity findings from the RLS Audit Report plus
  bundled medium/low gaps. Ships as a single migration with a paired
  rollback (`..._down.sql`).

  ## Findings addressed

  - H1 — privilege escalation via `user_profiles.role` self-promotion.
    Fixed with defense-in-depth: column-level REVOKE, BEFORE UPDATE
    trigger, and a WITH CHECK clause that forbids role changes.
  - H2 — `access_expires_at` column did not exist. Added here with an
    expiry-aware `private.has_enabled_access()` / `private.is_admin()`
    and a readable `public.is_enabled_user()` wrapper.
  - H3 — anon read of published content. Additive SELECT policies for
    anon on `events`, `event_tags`, `cities`, `tags`, `ratings`,
    `comments` (all scoped to published/approved/active rows).

  ## Bundled medium/low fixes

  - Restore `is_active = true` predicate on the cities enabled-user SELECT.
  - BEFORE UPDATE trigger on `comments` that resets `is_approved` when the
    editor is not admin.
  - `ALTER TABLE ... FORCE ROW LEVEL SECURITY` on gatekeeping tables.
  - Explicit `USING (false) WITH CHECK (false)` policies on
    `admin_audit_log` UPDATE/DELETE to encode append-only intent.
*/

-- =============================================================================
-- H2 — access_expires_at + expiry-aware helpers + public.is_enabled_user()
-- =============================================================================

ALTER TABLE public.user_access
  ADD COLUMN IF NOT EXISTS access_expires_at timestamptz;

COMMENT ON COLUMN public.user_access.access_expires_at IS
  'Optional access expiry. NULL means no expiry; access is active when is_enabled AND (access_expires_at IS NULL OR access_expires_at > now()).';

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

COMMENT ON FUNCTION private.has_enabled_access IS
  'Returns true when the current authenticated user has an enabled, unexpired user_access row.';

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

COMMENT ON FUNCTION private.is_admin IS
  'Returns true when the current user is an enabled, unexpired admin.';

CREATE OR REPLACE FUNCTION public.is_enabled_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.has_enabled_access();
$$;

COMMENT ON FUNCTION public.is_enabled_user IS
  'Readable wrapper over private.has_enabled_access() for use in policies and client code.';

REVOKE ALL ON FUNCTION public.is_enabled_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_enabled_user() TO authenticated;

-- =============================================================================
-- H1 — privilege escalation fix (defense-in-depth)
-- =============================================================================

-- Layer 1 — column-level REVOKE. PostgreSQL's column-level permission check
-- is `table-level OR column-level`, so we must revoke the table-level UPDATE
-- first and then re-grant UPDATE on every column except `role`. PostgREST
-- will then reject any PATCH that includes `role`.
REVOKE UPDATE ON public.user_profiles FROM authenticated;
REVOKE UPDATE ON public.user_profiles FROM anon;

GRANT UPDATE (email, display_name, avatar_url, city_preference_id, child_name, child_age, updated_at)
  ON public.user_profiles TO authenticated;

-- Layer 2 — BEFORE UPDATE trigger. SECURITY DEFINER so it can reach
-- private.is_admin(); a NULL auth.uid() indicates a trusted server-side
-- caller (postgres, service_role, SECURITY DEFINER RPCs, migrations, seeds).
CREATE OR REPLACE FUNCTION public.prevent_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    -- No JWT-bound user means server-side / SECURITY DEFINER context — allow.
    IF auth.uid() IS NULL THEN
      RETURN NEW;
    END IF;
    IF NOT private.is_admin() THEN
      RAISE EXCEPTION 'Only admins can change user_profiles.role'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.prevent_role_change IS
  'BEFORE UPDATE guard on user_profiles.role. Raises 42501 unless the caller is an admin or a server-side role without a JWT.';

REVOKE ALL ON FUNCTION public.prevent_role_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS prevent_role_change_on_profile ON public.user_profiles;
CREATE TRIGGER prevent_role_change_on_profile
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_role_change();

-- Layer 3 — WITH CHECK forbids role changes at the policy level. A direct
-- subquery on user_profiles would trigger PostgreSQL's 42P17 recursion
-- detection, so we route the lookup through a SECURITY DEFINER helper that
-- bypasses RLS.
CREATE OR REPLACE FUNCTION private.current_profile_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT role FROM public.user_profiles WHERE id = auth.uid();
$$;

COMMENT ON FUNCTION private.current_profile_role IS
  'Returns the current authenticated user''s user_profiles.role without triggering RLS on user_profiles.';

DROP POLICY IF EXISTS "Users can update own profile" ON public.user_profiles;
DROP POLICY IF EXISTS "Users can update own profile (non-privileged columns)" ON public.user_profiles;
CREATE POLICY "Users can update own profile (non-privileged columns)"
  ON public.user_profiles FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = id)
  WITH CHECK (
    (select auth.uid()) = id
    AND role IS NOT DISTINCT FROM (select private.current_profile_role())
  );

COMMENT ON POLICY "Users can update own profile (non-privileged columns)" ON public.user_profiles IS
  'Users can update their own profile fields but not role. Defense-in-depth: REVOKE UPDATE (role) + prevent_role_change trigger + this WITH CHECK.';

-- =============================================================================
-- H3 — anon read of published content
-- =============================================================================

-- events: anon can read only published events.
DROP POLICY IF EXISTS "Anon can read published events" ON public.events;
CREATE POLICY "Anon can read published events"
  ON public.events FOR SELECT
  TO anon
  USING (status = 'published');

COMMENT ON POLICY "Anon can read published events" ON public.events IS
  'Open-beta decision: anon/signed-out visitors can browse published events. Draft/rejected/archived rows stay hidden.';

-- event_tags: anon can read tag links only for published events.
DROP POLICY IF EXISTS "Anon can read event tags for published events" ON public.event_tags;
CREATE POLICY "Anon can read event tags for published events"
  ON public.event_tags FOR SELECT
  TO anon
  USING (
    EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = event_tags.event_id
        AND e.status = 'published'
    )
  );

COMMENT ON POLICY "Anon can read event tags for published events" ON public.event_tags IS
  'Supports anon browse: tag pills render on the public event list/detail.';

-- cities: anon can read active cities.
DROP POLICY IF EXISTS "Anon can read active cities" ON public.cities;
CREATE POLICY "Anon can read active cities"
  ON public.cities FOR SELECT
  TO anon
  USING (is_active = true);

COMMENT ON POLICY "Anon can read active cities" ON public.cities IS
  'Supports anon browse: city selector on /explore.';

-- tags: anon can read all tags (catalog is not sensitive).
DROP POLICY IF EXISTS "Anon can read tags" ON public.tags;
CREATE POLICY "Anon can read tags"
  ON public.tags FOR SELECT
  TO anon
  USING (true);

COMMENT ON POLICY "Anon can read tags" ON public.tags IS
  'Tags are a shared taxonomy, not sensitive. Anon can read to render tag filters.';

-- ratings: anon can read ratings for published events.
DROP POLICY IF EXISTS "Anon can read ratings for published events" ON public.ratings;
CREATE POLICY "Anon can read ratings for published events"
  ON public.ratings FOR SELECT
  TO anon
  USING (
    EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = ratings.event_id
        AND e.status = 'published'
    )
  );

COMMENT ON POLICY "Anon can read ratings for published events" ON public.ratings IS
  'Supports anon event detail: aggregated and individual ratings on published events only.';

-- comments: anon can read approved comments on published events.
DROP POLICY IF EXISTS "Anon can read approved comments on published events" ON public.comments;
CREATE POLICY "Anon can read approved comments on published events"
  ON public.comments FOR SELECT
  TO anon
  USING (
    is_approved = true
    AND EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = comments.event_id
        AND e.status = 'published'
    )
  );

COMMENT ON POLICY "Anon can read approved comments on published events" ON public.comments IS
  'Supports anon event detail: approved comments on published events. Unapproved/flagged stay hidden.';

-- Restore anon access to the event_rating_stats view since ratings now has an
-- anon SELECT policy. The view is security_invoker so RLS still applies.
GRANT SELECT ON public.event_rating_stats TO anon;

-- =============================================================================
-- Bundled fix: restore is_active predicate on cities enabled-user SELECT
-- =============================================================================

DROP POLICY IF EXISTS "Enabled users can read cities" ON public.cities;
CREATE POLICY "Enabled users can read cities"
  ON public.cities FOR SELECT
  TO authenticated
  USING (
    (select private.is_admin())
    OR (
      (select private.has_enabled_access())
      AND is_active = true
    )
  );

COMMENT ON POLICY "Enabled users can read cities" ON public.cities IS
  'Enabled users see active cities; admins see all cities (including inactive) for management.';


-- =============================================================================
-- Bundled fix: prevent non-admin from flipping comments.is_approved on update
-- =============================================================================

CREATE OR REPLACE FUNCTION public.reset_comment_approval_for_non_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.is_approved IS DISTINCT FROM OLD.is_approved THEN
    -- No JWT means server-side / SECURITY DEFINER context — allow the change.
    IF auth.uid() IS NOT NULL AND NOT private.is_admin() THEN
      NEW.is_approved := OLD.is_approved;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.reset_comment_approval_for_non_admin IS
  'BEFORE UPDATE guard on comments.is_approved. Silently reverts non-admin edits to is_approved so users cannot self-approve.';

REVOKE ALL ON FUNCTION public.reset_comment_approval_for_non_admin() FROM PUBLIC;

DROP TRIGGER IF EXISTS reset_comment_approval_on_update ON public.comments;
CREATE TRIGGER reset_comment_approval_on_update
  BEFORE UPDATE ON public.comments
  FOR EACH ROW
  EXECUTE FUNCTION public.reset_comment_approval_for_non_admin();

-- =============================================================================
-- Bundled fix: FORCE ROW LEVEL SECURITY on gatekeeping tables
-- =============================================================================
-- FORCE RLS applies even to the table owner. Roles with BYPASSRLS (postgres,
-- service_role, supabase_admin) still bypass; this just closes the owner gap.

ALTER TABLE public.user_profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_access FORCE ROW LEVEL SECURITY;
ALTER TABLE public.invite_codes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.pending_invite_claims FORCE ROW LEVEL SECURITY;

-- =============================================================================
-- Bundled fix: explicit deny policies on admin_audit_log mutations
-- =============================================================================
-- Audit log is append-only. These RESTRICTIVE policies make the intent
-- explicit and prevent a future migration from accidentally adding a
-- permissive UPDATE/DELETE policy without review.

DROP POLICY IF EXISTS "Deny audit log updates" ON public.admin_audit_log;
CREATE POLICY "Deny audit log updates"
  ON public.admin_audit_log
  AS RESTRICTIVE
  FOR UPDATE
  TO authenticated, anon
  USING (false)
  WITH CHECK (false);

COMMENT ON POLICY "Deny audit log updates" ON public.admin_audit_log IS
  'Audit log is append-only. Restrictive policy blocks all UPDATE via PostgREST.';

DROP POLICY IF EXISTS "Deny audit log deletes" ON public.admin_audit_log;
CREATE POLICY "Deny audit log deletes"
  ON public.admin_audit_log
  AS RESTRICTIVE
  FOR DELETE
  TO authenticated, anon
  USING (false);

COMMENT ON POLICY "Deny audit log deletes" ON public.admin_audit_log IS
  'Audit log is append-only. Restrictive policy blocks all DELETE via PostgREST.';
