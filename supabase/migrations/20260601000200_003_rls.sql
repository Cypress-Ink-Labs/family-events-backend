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
DROP POLICY IF EXISTS "Anon can read active cities" ON public.cities;
CREATE POLICY "Anon can read active cities"
  ON public.cities FOR SELECT TO anon
  USING (is_active = true);

DROP POLICY IF EXISTS "Enabled users can read cities" ON public.cities;
CREATE POLICY "Enabled users can read cities"
  ON public.cities FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND is_active = true
    )
  );

DROP POLICY IF EXISTS "Admins can insert cities" ON public.cities;
CREATE POLICY "Admins can insert cities"
  ON public.cities FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update cities" ON public.cities;
CREATE POLICY "Admins can update cities"
  ON public.cities FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete cities" ON public.cities;
CREATE POLICY "Admins can delete cities"
  ON public.cities FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- tags
-- =============================================
DROP POLICY IF EXISTS "Anon can read tags" ON public.tags;
CREATE POLICY "Anon can read tags"
  ON public.tags FOR SELECT TO anon
  USING (true);

DROP POLICY IF EXISTS "Enabled users can read tags" ON public.tags;
CREATE POLICY "Enabled users can read tags"
  ON public.tags FOR SELECT TO authenticated
  USING ((SELECT private.has_enabled_access()));

DROP POLICY IF EXISTS "Admins can insert tags" ON public.tags;
CREATE POLICY "Admins can insert tags"
  ON public.tags FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update tags" ON public.tags;
CREATE POLICY "Admins can update tags"
  ON public.tags FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete tags" ON public.tags;
CREATE POLICY "Admins can delete tags"
  ON public.tags FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- user_profiles
-- =============================================
DROP POLICY IF EXISTS "Users can view own profile or admins can view all profiles" ON public.user_profiles;
CREATE POLICY "Users can view own profile or admins can view all profiles"
  ON public.user_profiles FOR SELECT TO authenticated
  USING (
    (SELECT auth.uid()) = id
    OR (SELECT private.is_admin())
  );

-- WITH CHECK additionally pins role='user' on INSERT. Defense-in-depth:
-- REVOKE and the trigger protect UPDATE; this protects INSERT against a
-- user creating their own row with role='admin' on first sign-in.
DROP POLICY IF EXISTS "Users can insert own profile" ON public.user_profiles;
CREATE POLICY "Users can insert own profile"
  ON public.user_profiles FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT auth.uid()) = id
    AND role = 'user'
  );

-- WITH CHECK prevents role self-escalation at the policy layer.
-- Defense-in-depth: REVOKE + prevent_role_change trigger also guard this.
DROP POLICY IF EXISTS "Users can update own profile (non-privileged columns)" ON public.user_profiles;
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
DROP POLICY IF EXISTS "Admins can select sources" ON public.event_sources;
CREATE POLICY "Admins can select sources"
  ON public.event_sources FOR SELECT TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can insert sources" ON public.event_sources;
CREATE POLICY "Admins can insert sources"
  ON public.event_sources FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update sources" ON public.event_sources;
CREATE POLICY "Admins can update sources"
  ON public.event_sources FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete sources" ON public.event_sources;
CREATE POLICY "Admins can delete sources"
  ON public.event_sources FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- source_runs
-- =============================================
DROP POLICY IF EXISTS "Admins can select source runs" ON public.source_runs;
CREATE POLICY "Admins can select source runs"
  ON public.source_runs FOR SELECT TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can insert source runs" ON public.source_runs;
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

DROP POLICY IF EXISTS "Authenticated users can read published events or admins can read all events" ON public.events;
CREATE POLICY "Authenticated users can read published events or admins can read all events"
  ON public.events FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND status = 'published'
    )
  );

DROP POLICY IF EXISTS "Admins can insert events" ON public.events;
CREATE POLICY "Admins can insert events"
  ON public.events FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update events" ON public.events;
CREATE POLICY "Admins can update events"
  ON public.events FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete events" ON public.events;
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
DROP POLICY IF EXISTS "Anon can read event tags for published events" ON public.event_tags;
CREATE POLICY "Anon can read event tags for published events"
  ON public.event_tags FOR SELECT TO anon
  USING (
    EXISTS (
      SELECT 1 FROM public.public_events pe
      WHERE pe.id = event_tags.event_id
    )
  );

-- Mirror the anon gate for authenticated non-admins: enabled users see tags
-- only for published events. Admins still see all tags (drafts included)
-- through the bypass branch.
DROP POLICY IF EXISTS "Enabled users can read event tags" ON public.event_tags;
CREATE POLICY "Enabled users can read event tags"
  ON public.event_tags FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND EXISTS (
        SELECT 1 FROM public.events e
        WHERE e.id = event_tags.event_id AND e.status = 'published'
      )
    )
  );

DROP POLICY IF EXISTS "Admins can insert event tags" ON public.event_tags;
CREATE POLICY "Admins can insert event tags"
  ON public.event_tags FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update event tags" ON public.event_tags;
CREATE POLICY "Admins can update event tags"
  ON public.event_tags FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete event tags" ON public.event_tags;
CREATE POLICY "Admins can delete event tags"
  ON public.event_tags FOR DELETE TO authenticated
  USING (private.is_admin());

-- =============================================
-- favorites
-- =============================================
DROP POLICY IF EXISTS "Enabled users can view own favorites" ON public.favorites;
CREATE POLICY "Enabled users can view own favorites"
  ON public.favorites FOR SELECT TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Enabled users can add favorites" ON public.favorites;
CREATE POLICY "Enabled users can add favorites"
  ON public.favorites FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Enabled users can delete own favorites" ON public.favorites;
CREATE POLICY "Enabled users can delete own favorites"
  ON public.favorites FOR DELETE TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

-- =============================================
-- user_calendar_events
-- =============================================
DROP POLICY IF EXISTS "Enabled users can view own calendar events" ON public.user_calendar_events;
CREATE POLICY "Enabled users can view own calendar events"
  ON public.user_calendar_events FOR SELECT TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Enabled users can add calendar events" ON public.user_calendar_events;
CREATE POLICY "Enabled users can add calendar events"
  ON public.user_calendar_events FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Enabled users can delete own calendar events" ON public.user_calendar_events;
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
DROP POLICY IF EXISTS "Anon can read ratings for published events" ON public.ratings;
CREATE POLICY "Anon can read ratings for published events"
  ON public.ratings FOR SELECT TO anon
  USING (
    EXISTS (
      SELECT 1 FROM public.public_events pe
      WHERE pe.id = ratings.event_id
    )
  );

-- Mirror anon gate for authenticated non-admins: see ratings only for
-- published events. Admins bypass via is_admin() branch.
DROP POLICY IF EXISTS "Enabled users can read ratings" ON public.ratings;
CREATE POLICY "Enabled users can read ratings"
  ON public.ratings FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND EXISTS (
        SELECT 1 FROM public.events e
        WHERE e.id = ratings.event_id AND e.status = 'published'
      )
    )
  );

DROP POLICY IF EXISTS "Enabled users can add ratings" ON public.ratings;
CREATE POLICY "Enabled users can add ratings"
  ON public.ratings FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Enabled users can update own ratings" ON public.ratings;
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

DROP POLICY IF EXISTS "Enabled users can delete own ratings" ON public.ratings;
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
DROP POLICY IF EXISTS "Anon can read approved comments on published events" ON public.comments;
CREATE POLICY "Anon can read approved comments on published events"
  ON public.comments FOR SELECT TO anon
  USING (
    is_approved = true
    AND EXISTS (
      SELECT 1 FROM public.public_events pe
      WHERE pe.id = comments.event_id
    )
  );

-- Non-admin authenticated readers see approved comments only on published
-- events. Admins see everything (drafts + unapproved). This mirrors the
-- anon gate so a draft event's comments are not leaked through the
-- comments table when the event itself is hidden by the events policy.
DROP POLICY IF EXISTS "Authenticated users can read approved comments or admins can read all comments" ON public.comments;
CREATE POLICY "Authenticated users can read approved comments or admins can read all comments"
  ON public.comments FOR SELECT TO authenticated
  USING (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND is_approved = true
      AND EXISTS (
        SELECT 1 FROM public.events e
        WHERE e.id = comments.event_id AND e.status = 'published'
      )
    )
  );

DROP POLICY IF EXISTS "Authenticated users can insert own comments or admins can insert comments" ON public.comments;
CREATE POLICY "Authenticated users can insert own comments or admins can insert comments"
  ON public.comments FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.is_admin())
    OR (
      (SELECT private.has_enabled_access())
      AND (SELECT auth.uid()) = user_id
    )
  );

DROP POLICY IF EXISTS "Authenticated users can update own comments or admins can update comments" ON public.comments;
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

DROP POLICY IF EXISTS "Authenticated users can delete own comments or admins can delete comments" ON public.comments;
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
DROP POLICY IF EXISTS "Enabled users can view own signals" ON public.recommendation_signals;
CREATE POLICY "Enabled users can view own signals"
  ON public.recommendation_signals FOR SELECT TO authenticated
  USING (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

DROP POLICY IF EXISTS "Enabled users can insert signals" ON public.recommendation_signals;
CREATE POLICY "Enabled users can insert signals"
  ON public.recommendation_signals FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT private.has_enabled_access())
    AND (SELECT auth.uid()) = user_id
  );

-- =============================================
-- admin_audit_log (append-only)
-- =============================================
DROP POLICY IF EXISTS "Admins can read audit log" ON public.admin_audit_log;
CREATE POLICY "Admins can read audit log"
  ON public.admin_audit_log FOR SELECT TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can insert audit log" ON public.admin_audit_log;
CREATE POLICY "Admins can insert audit log"
  ON public.admin_audit_log FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Deny audit log updates" ON public.admin_audit_log;
CREATE POLICY "Deny audit log updates"
  ON public.admin_audit_log AS RESTRICTIVE FOR UPDATE
  TO authenticated, anon
  USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS "Deny audit log deletes" ON public.admin_audit_log;
CREATE POLICY "Deny audit log deletes"
  ON public.admin_audit_log AS RESTRICTIVE FOR DELETE
  TO authenticated, anon
  USING (false);

-- =============================================
-- invite_codes
-- =============================================
DROP POLICY IF EXISTS "Admins can manage invite codes" ON public.invite_codes;
CREATE POLICY "Admins can manage invite codes"
  ON public.invite_codes FOR ALL TO authenticated
  USING (private.is_admin())
  WITH CHECK (private.is_admin());

-- =============================================
-- user_access
-- =============================================
DROP POLICY IF EXISTS "Users can view own access or admins can view all access" ON public.user_access;
CREATE POLICY "Users can view own access or admins can view all access"
  ON public.user_access FOR SELECT TO authenticated
  USING (
    (SELECT auth.uid()) = user_id
    OR (SELECT private.is_admin())
  );

DROP POLICY IF EXISTS "Admins can insert user access" ON public.user_access;
CREATE POLICY "Admins can insert user access"
  ON public.user_access FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.is_admin()));

DROP POLICY IF EXISTS "Admins can update user access" ON public.user_access;
CREATE POLICY "Admins can update user access"
  ON public.user_access FOR UPDATE TO authenticated
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));

DROP POLICY IF EXISTS "Admins can delete user access" ON public.user_access;
CREATE POLICY "Admins can delete user access"
  ON public.user_access FOR DELETE TO authenticated
  USING ((SELECT private.is_admin()));

-- =============================================
-- pending_invite_claims
-- All access is via SECURITY DEFINER RPCs only.
-- =============================================
DROP POLICY IF EXISTS "No direct access to pending invite claims" ON public.pending_invite_claims;
CREATE POLICY "No direct access to pending invite claims"
  ON public.pending_invite_claims FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

-- =============================================
-- event_ai_traces
-- =============================================
DROP POLICY IF EXISTS "Admins can read AI traces" ON public.event_ai_traces;
CREATE POLICY "Admins can read AI traces"
  ON public.event_ai_traces FOR SELECT TO authenticated
  USING (private.is_admin());
