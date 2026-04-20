/*
  # Down migration for 20260420010000_rls_audit_fixes.sql

  Best-effort rollback. Reverses the policy/trigger/column changes so the DB
  returns to the state after 20260419031645_fix_function_search_path.sql.
  Apply with `psql "$DB_URL" -f supabase/migrations/20260420010000_rls_audit_fixes_down.sql`.

  Caveats:
  - `access_expires_at` data is dropped. Back it up before rolling back if any
    rows have been written.
  - Column-level REVOKE on user_profiles.role is restored by re-granting
    UPDATE on the entire row (matches the prior default grant from PostgREST).
*/

-- -----------------------------------------------------------------------------
-- Audit log: drop explicit deny policies (absence of policy already denies).
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Deny audit log deletes" ON public.admin_audit_log;
DROP POLICY IF EXISTS "Deny audit log updates" ON public.admin_audit_log;

-- -----------------------------------------------------------------------------
-- FORCE RLS off on gatekeeping tables.
-- -----------------------------------------------------------------------------
ALTER TABLE public.pending_invite_claims NO FORCE ROW LEVEL SECURITY;
ALTER TABLE public.invite_codes NO FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_access NO FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles NO FORCE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- Comments: drop the is_approved reset trigger and function.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS reset_comment_approval_on_update ON public.comments;
DROP FUNCTION IF EXISTS public.reset_comment_approval_for_non_admin();

-- -----------------------------------------------------------------------------
-- Cities: restore the prior enabled-user SELECT policy (no is_active predicate).
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Enabled users can read cities" ON public.cities;
CREATE POLICY "Enabled users can read cities"
  ON public.cities FOR SELECT
  TO authenticated
  USING ((select private.has_enabled_access()));

-- -----------------------------------------------------------------------------
-- H3: drop anon SELECT policies and re-revoke event_rating_stats from anon.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anon can read approved comments on published events" ON public.comments;
DROP POLICY IF EXISTS "Anon can read ratings for published events" ON public.ratings;
DROP POLICY IF EXISTS "Anon can read tags" ON public.tags;
DROP POLICY IF EXISTS "Anon can read active cities" ON public.cities;
DROP POLICY IF EXISTS "Anon can read event tags for published events" ON public.event_tags;
DROP POLICY IF EXISTS "Anon can read published events" ON public.events;

REVOKE SELECT ON public.event_rating_stats FROM anon;

-- -----------------------------------------------------------------------------
-- H1: restore the original user_profiles UPDATE policy (without the role guard),
-- drop the prevent_role_change trigger/function, and re-grant UPDATE (role).
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can update own profile (non-privileged columns)" ON public.user_profiles;
CREATE POLICY "Users can update own profile"
  ON public.user_profiles FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = id)
  WITH CHECK ((select auth.uid()) = id);

DROP TRIGGER IF EXISTS prevent_role_change_on_profile ON public.user_profiles;
DROP FUNCTION IF EXISTS public.prevent_role_change();
DROP FUNCTION IF EXISTS private.current_profile_role();

-- Restore the broad table-level UPDATE grant that Supabase ships by default.
REVOKE UPDATE (email, display_name, avatar_url, city_preference_id, child_name, child_age, updated_at)
  ON public.user_profiles FROM authenticated;
GRANT UPDATE ON public.user_profiles TO authenticated;

-- -----------------------------------------------------------------------------
-- H2: drop is_enabled_user wrapper, restore prior helpers, drop the column.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.is_enabled_user();

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

ALTER TABLE public.user_access DROP COLUMN IF EXISTS access_expires_at;
