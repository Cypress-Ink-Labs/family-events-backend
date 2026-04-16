/*
  # Fix admin RLS infinite recursion

  The "Admins can view all profiles" policy on user_profiles queries
  user_profiles itself, causing infinite recursion. Every other admin
  policy also subqueries user_profiles, hitting the same cycle.

  Fix: a SECURITY DEFINER function that bypasses RLS for the admin check.
*/

-- Private schema for internal functions not exposed via the Data API
CREATE SCHEMA IF NOT EXISTS private;

-- Admin check function — SECURITY DEFINER bypasses RLS on the inner query
CREATE OR REPLACE FUNCTION private.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

-- Drop the recursive policy
DROP POLICY IF EXISTS "Admins can view all profiles" ON user_profiles;

-- Recreate it using the safe function
CREATE POLICY "Admins can view all profiles"
  ON user_profiles FOR SELECT
  TO authenticated
  USING (private.is_admin());

-- Update all other admin policies to use the function too,
-- eliminating redundant subqueries and preventing future recursion.

-- cities
DROP POLICY IF EXISTS "Admins can insert cities" ON cities;
CREATE POLICY "Admins can insert cities"
  ON cities FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update cities" ON cities;
CREATE POLICY "Admins can update cities"
  ON cities FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete cities" ON cities;
CREATE POLICY "Admins can delete cities"
  ON cities FOR DELETE TO authenticated
  USING (private.is_admin());

-- tags
DROP POLICY IF EXISTS "Admins can insert tags" ON tags;
CREATE POLICY "Admins can insert tags"
  ON tags FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update tags" ON tags;
CREATE POLICY "Admins can update tags"
  ON tags FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete tags" ON tags;
CREATE POLICY "Admins can delete tags"
  ON tags FOR DELETE TO authenticated
  USING (private.is_admin());

-- event_sources
DROP POLICY IF EXISTS "Admins can select sources" ON event_sources;
CREATE POLICY "Admins can select sources"
  ON event_sources FOR SELECT TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can insert sources" ON event_sources;
CREATE POLICY "Admins can insert sources"
  ON event_sources FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update sources" ON event_sources;
CREATE POLICY "Admins can update sources"
  ON event_sources FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete sources" ON event_sources;
CREATE POLICY "Admins can delete sources"
  ON event_sources FOR DELETE TO authenticated
  USING (private.is_admin());

-- source_runs
DROP POLICY IF EXISTS "Admins can select source runs" ON source_runs;
CREATE POLICY "Admins can select source runs"
  ON source_runs FOR SELECT TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can insert source runs" ON source_runs;
CREATE POLICY "Admins can insert source runs"
  ON source_runs FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

-- events
DROP POLICY IF EXISTS "Admins can select all events" ON events;
CREATE POLICY "Admins can select all events"
  ON events FOR SELECT TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can insert events" ON events;
CREATE POLICY "Admins can insert events"
  ON events FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update events" ON events;
CREATE POLICY "Admins can update events"
  ON events FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete events" ON events;
CREATE POLICY "Admins can delete events"
  ON events FOR DELETE TO authenticated
  USING (private.is_admin());

-- event_tags
DROP POLICY IF EXISTS "Admins can insert event tags" ON event_tags;
CREATE POLICY "Admins can insert event tags"
  ON event_tags FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can update event tags" ON event_tags;
CREATE POLICY "Admins can update event tags"
  ON event_tags FOR UPDATE TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

DROP POLICY IF EXISTS "Admins can delete event tags" ON event_tags;
CREATE POLICY "Admins can delete event tags"
  ON event_tags FOR DELETE TO authenticated
  USING (private.is_admin());

-- comments
DROP POLICY IF EXISTS "Admins can manage comments" ON comments;
CREATE POLICY "Admins can manage comments"
  ON comments FOR ALL TO authenticated
  USING (private.is_admin()) WITH CHECK (private.is_admin());

-- admin_audit_log
DROP POLICY IF EXISTS "Admins can read audit log" ON admin_audit_log;
CREATE POLICY "Admins can read audit log"
  ON admin_audit_log FOR SELECT TO authenticated
  USING (private.is_admin());

DROP POLICY IF EXISTS "Admins can insert audit log" ON admin_audit_log;
CREATE POLICY "Admins can insert audit log"
  ON admin_audit_log FOR INSERT TO authenticated
  WITH CHECK (private.is_admin());
