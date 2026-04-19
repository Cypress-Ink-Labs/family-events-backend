/*
  # Fix Supabase advisor performance warnings for RLS policies

  Resolves:
  - auth_rls_initplan warnings on public.user_profiles by wrapping auth.uid()
    in SELECT for statement-level initPlans.
  - multiple_permissive_policies warnings by collapsing overlapping user/admin
    policies into a single policy per role/action pair on the flagged tables.
*/

-- -----------------------------------------------------------------------------
-- public.user_profiles
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own profile" ON public.user_profiles;
DROP POLICY IF EXISTS "Admins can view all profiles" ON public.user_profiles;

CREATE POLICY "Users can view own profile or admins can view all profiles"
  ON public.user_profiles FOR SELECT
  TO authenticated
  USING (
    (select auth.uid()) = id
    OR (select private.is_admin())
  );

DROP POLICY IF EXISTS "Users can insert own profile" ON public.user_profiles;
CREATE POLICY "Users can insert own profile"
  ON public.user_profiles FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.user_profiles;
CREATE POLICY "Users can update own profile"
  ON public.user_profiles FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = id)
  WITH CHECK ((select auth.uid()) = id);

-- -----------------------------------------------------------------------------
-- public.events
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Enabled users can read published events" ON public.events;
DROP POLICY IF EXISTS "Admins can select all events" ON public.events;

CREATE POLICY "Authenticated users can read published events or admins can read all events"
  ON public.events FOR SELECT
  TO authenticated
  USING (
    (select private.is_admin())
    OR (
      (select private.has_enabled_access())
      AND status = 'published'
    )
  );

-- -----------------------------------------------------------------------------
-- public.user_access
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own access" ON public.user_access;
DROP POLICY IF EXISTS "Admins can manage user access" ON public.user_access;

CREATE POLICY "Users can view own access or admins can view all access"
  ON public.user_access FOR SELECT
  TO authenticated
  USING (
    (select auth.uid()) = user_id
    OR (select private.is_admin())
  );

CREATE POLICY "Admins can insert user access"
  ON public.user_access FOR INSERT
  TO authenticated
  WITH CHECK ((select private.is_admin()));

CREATE POLICY "Admins can update user access"
  ON public.user_access FOR UPDATE
  TO authenticated
  USING ((select private.is_admin()))
  WITH CHECK ((select private.is_admin()));

CREATE POLICY "Admins can delete user access"
  ON public.user_access FOR DELETE
  TO authenticated
  USING ((select private.is_admin()));

-- -----------------------------------------------------------------------------
-- public.comments
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Enabled users can read approved comments" ON public.comments;
DROP POLICY IF EXISTS "Enabled users can add comments" ON public.comments;
DROP POLICY IF EXISTS "Enabled users can update own comments" ON public.comments;
DROP POLICY IF EXISTS "Enabled users can delete own comments" ON public.comments;
DROP POLICY IF EXISTS "Admins can manage comments" ON public.comments;

CREATE POLICY "Authenticated users can read approved comments or admins can read all comments"
  ON public.comments FOR SELECT
  TO authenticated
  USING (
    (select private.is_admin())
    OR (
      (select private.has_enabled_access())
      AND is_approved = true
    )
  );

CREATE POLICY "Authenticated users can insert own comments or admins can insert comments"
  ON public.comments FOR INSERT
  TO authenticated
  WITH CHECK (
    (select private.is_admin())
    OR (
      (select private.has_enabled_access())
      AND (select auth.uid()) = user_id
    )
  );

CREATE POLICY "Authenticated users can update own comments or admins can update comments"
  ON public.comments FOR UPDATE
  TO authenticated
  USING (
    (select private.is_admin())
    OR (
      (select private.has_enabled_access())
      AND (select auth.uid()) = user_id
    )
  )
  WITH CHECK (
    (select private.is_admin())
    OR (
      (select private.has_enabled_access())
      AND (select auth.uid()) = user_id
    )
  );

CREATE POLICY "Authenticated users can delete own comments or admins can delete comments"
  ON public.comments FOR DELETE
  TO authenticated
  USING (
    (select private.is_admin())
    OR (
      (select private.has_enabled_access())
      AND (select auth.uid()) = user_id
    )
  );
