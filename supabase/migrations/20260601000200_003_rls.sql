/*
  # Family Events Platform — RLS Policies

  Final policy set. All intermediate DROP/recreate cycles from the migration
  history are collapsed here into the definitive policy per table × action.

  Security model summary:
  - anon: read published/active content only
  - enabled authenticated: read + write own data
  - admin: full access everywhere
  - user_profiles.role: hardened with REVOKE + trigger + WITH CHECK
  - admin_audit_log: append-only (RESTRICTIVE deny on UPDATE/DELETE)
  - invite/access tables: FORCE ROW LEVEL SECURITY applied in schema
*/

-- =============================================
-- cities
-- =============================================
CREATE POLICY "Anon can read active cities"
  ON public.cities FOR SELECT TO anon
  USING (is_active = true);

CREATE POLICY "Enabled users can read cities"
  ON public.cities FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND is_active = true
    )
  );

CREATE POLICY "Admins can insert cities"
  ON public.cities FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

CREATE POLICY "Admins can update cities"
  ON public.cities FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

CREATE POLICY "Admins can delete cities"
  ON public.cities FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- tags
-- =============================================
CREATE POLICY "Anon can read tags"
  ON public.tags FOR SELECT TO anon
  USING (true);

CREATE POLICY "Enabled users can read tags"
  ON public.tags FOR SELECT TO authenticated
  USING ((SELECT private.has_enabled_access()));

CREATE POLICY "Admins can insert tags"
  ON public.tags FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

CREATE POLICY "Admins can update tags"
  ON public.tags FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

CREATE POLICY "Admins can delete tags"
  ON public.tags FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- user_profiles
-- =============================================
CREATE POLICY "Users can view own profile or admins can view all profiles"
  ON public.user_profiles FOR SELECT TO authenticated
  USING (
    (SELECT auth.uid()) = id
    OR (SELECT private.is_admin())
  );

CREATE POLICY "Users can insert own profile"
  ON public.user_profiles FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = id);

-- WITH CHECK prevents role self-escalation at the policy layer.
-- Defense-in-depth: REVOKE + prevent_role_change trigger also guard this.
CREATE POLICY "Users can update own profile (non-privileged columns)"
  ON public.user_profiles FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = id)
  WITH CHECK (
    (SELECT auth.uid()) = id
    AND role IS NOT DISTINCT FROM (SELECT private.current_profile_role())
  );

-- =============================================
-- event_sources
-- =============================================
CREATE POLICY "Admins can select sources"
  ON public.event_sources FOR SELECT TO authenticated
  USING (private.is_admin());

CREATE POLICY "Admins can insert sources"
  ON public.event_sources FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

CREATE POLICY "Admins can update sources"
  ON public.event_sources FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

CREATE POLICY "Admins can delete sources"
  ON public.event_sources FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- source_runs
-- =============================================
CREATE POLICY "Admins can select source runs"
  ON public.source_runs FOR SELECT TO authenticated
  USING (private.is_admin());

CREATE POLICY "Admins can insert source runs"
  ON public.source_runs FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

-- =============================================
-- events
-- anon reads via public_events view (see views file).
-- Raw anon SELECT on events is intentionally absent.
--
-- FORCE RLS belt-and-braces: SECURITY DEFINER functions that touch events
-- (e.g. owned-by-postgres helpers) still pass through these policies,
-- preventing accidental privilege escalation through function ownership.
-- =============================================
ALTER TABLE public.events FORCE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read published events or admins can read all events"
  ON public.events FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND status = 'published'
    )
  );

CREATE POLICY "Admins can insert events"
  ON public.events FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

CREATE POLICY "Admins can update events"
  ON public.events FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

CREATE POLICY "Admins can delete events"
  ON public.events FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- event_tags
-- =============================================
-- Subquery targets public.public_events (anon has SELECT grant) instead of
-- public.events (anon has no SELECT policy). Reading public.events from inside
-- this USING clause would return zero rows for anon and silently break tag
-- chips on the share/event-detail page. The view filters status='published'.
CREATE POLICY "Anon can read event tags for published events"
  ON public.event_tags FOR SELECT TO anon
  USING (
    EXISTS (
      SELECT 1 FROM public.public_events pe
      WHERE pe.id = event_tags.event_id
    )
  );

CREATE POLICY "Enabled users can read event tags"
  ON public.event_tags FOR SELECT TO authenticated
  USING ((SELECT private.has_enabled_access()));

CREATE POLICY "Admins can insert event tags"
  ON public.event_tags FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

CREATE POLICY "Admins can update event tags"
  ON public.event_tags FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

CREATE POLICY "Admins can delete event tags"
  ON public.event_tags FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- favorites
-- =============================================
CREATE POLICY "Enabled users can view own favorites"
  ON public.favorites FOR SELECT TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

CREATE POLICY "Enabled users can add favorites"
  ON public.favorites FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

CREATE POLICY "Enabled users can delete own favorites"
  ON public.favorites FOR DELETE TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

-- =============================================
-- user_calendar_events
-- =============================================
CREATE POLICY "Enabled users can view own calendar events"
  ON public.user_calendar_events FOR SELECT TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

CREATE POLICY "Enabled users can add calendar events"
  ON public.user_calendar_events FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

CREATE POLICY "Enabled users can delete own calendar events"
  ON public.user_calendar_events FOR DELETE TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

-- =============================================
-- ratings
-- =============================================
-- Subquery targets public.public_events (see event_tags note above).
-- event_rating_stats view is security_invoker, so it relies on this policy
-- for anon access to aggregated rating counts on published events.
CREATE POLICY "Anon can read ratings for published events"
  ON public.ratings FOR SELECT TO anon
  USING (
    EXISTS (
      SELECT 1 FROM public.public_events pe
      WHERE pe.id = ratings.event_id
    )
  );

CREATE POLICY "Enabled users can read ratings"
  ON public.ratings FOR SELECT TO authenticated
  USING ((SELECT private.has_enabled_access()));

CREATE POLICY "Enabled users can add ratings"
  ON public.ratings FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

CREATE POLICY "Enabled users can update own ratings"
  ON public.ratings FOR UPDATE TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  )
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

CREATE POLICY "Enabled users can delete own ratings"
  ON public.ratings FOR DELETE TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

-- =============================================
-- comments
-- =============================================
-- Subquery targets public.public_events (see event_tags note above).
CREATE POLICY "Anon can read approved comments on published events"
  ON public.comments FOR SELECT TO anon
  USING (
    is_approved = true
    AND EXISTS (
      SELECT 1 FROM public.public_events pe
      WHERE pe.id = comments.event_id
    )
  );

CREATE POLICY "Authenticated users can read approved comments or admins can read all comments"
  ON public.comments FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND is_approved = true
    )
  );

CREATE POLICY "Authenticated users can insert own comments or admins can insert comments"
  ON public.comments FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND (SELECT auth.uid()) = user_id
    )
  );

CREATE POLICY "Authenticated users can update own comments or admins can update comments"
  ON public.comments FOR UPDATE TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND (SELECT auth.uid()) = user_id
    )
  )
  WITH CHECK (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND (SELECT auth.uid()) = user_id
    )
  );

CREATE POLICY "Authenticated users can delete own comments or admins can delete comments"
  ON public.comments FOR DELETE TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND (SELECT auth.uid()) = user_id
    )
  );

-- =============================================
-- recommendation_signals
-- =============================================
CREATE POLICY "Enabled users can view own signals"
  ON public.recommendation_signals FOR SELECT TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

CREATE POLICY "Enabled users can insert signals"
  ON public.recommendation_signals FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

-- =============================================
-- admin_audit_log (append-only)
-- =============================================
CREATE POLICY "Admins can read audit log"
  ON public.admin_audit_log FOR SELECT TO authenticated
  USING (private.is_admin());

CREATE POLICY "Admins can insert audit log"
  ON public.admin_audit_log FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

CREATE POLICY "Deny audit log updates"
  ON public.admin_audit_log AS RESTRICTIVE FOR UPDATE
  TO authenticated, anon
  USING (false) WITH CHECK (false);

CREATE POLICY "Deny audit log deletes"
  ON public.admin_audit_log AS RESTRICTIVE FOR DELETE
  TO authenticated, anon
  USING (false);

-- =============================================
-- invite_codes
-- =============================================
CREATE POLICY "Admins can manage invite codes"
  ON public.invite_codes FOR ALL TO authenticated
  USING (private.is_admin())
  WITH CHECK (private.is_admin());

-- =============================================
-- user_access
-- =============================================
CREATE POLICY "Users can view own access or admins can view all access"
  ON public.user_access FOR SELECT TO authenticated
  USING (
    (SELECT auth.uid()) = user_id
    OR (SELECT private.is_admin())
  );

CREATE POLICY "Admins can insert user access"
  ON public.user_access FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.is_admin()));

CREATE POLICY "Admins can update user access"
  ON public.user_access FOR UPDATE TO authenticated
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));

CREATE POLICY "Admins can delete user access"
  ON public.user_access FOR DELETE TO authenticated
  USING ((SELECT private.is_admin()));

-- =============================================
-- pending_invite_claims
-- All access is via SECURITY DEFINER RPCs only.
-- =============================================
CREATE POLICY "No direct access to pending invite claims"
  ON public.pending_invite_claims FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

-- =============================================
-- event_ai_traces
-- =============================================
CREATE POLICY "Admins can read AI traces"
  ON public.event_ai_traces FOR SELECT TO authenticated
  USING (private.is_admin());
