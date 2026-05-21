-- Consolidate SELECT policies on public.events so the advisor lint
-- 0006_multiple_permissive_policies stops firing for role `authenticated`.
--
-- State before this migration:
--   * "Anyone can read published events"            TO anon, authenticated  USING (status = 'published')
--   * "Authenticated users can read published events or admins can read all events"
--                                                   TO authenticated         USING (is_admin() OR (has_enabled_access() AND status = 'published'))
--
-- The two permissive policies overlap on authenticated/SELECT, so the planner
-- runs both per row. They also leave `has_enabled_access()` as dead weight:
-- any authenticated row that satisfies the second policy already satisfies the
-- first via the published-status branch, so the access gate has been a no-op
-- for SELECT since 20260601001800 added the open published policy.
--
-- After this migration:
--   * anon:          "Anon can read published events"           USING (status = 'published')
--   * authenticated: "Authenticated reads published or admin reads all"
--                                                              USING (is_admin() OR status = 'published')
--
-- Effective row visibility is unchanged: every row visible under the prior
-- pair remains visible, and no extra rows leak.

BEGIN;

DROP POLICY IF EXISTS "Anyone can read published events" ON public.events;
DROP POLICY IF EXISTS "Authenticated users can read published events or admins can read all events" ON public.events;

CREATE POLICY "Anon can read published events"
  ON public.events
  FOR SELECT
  TO anon
  USING (status = 'published');

CREATE POLICY "Authenticated reads published or admin reads all"
  ON public.events
  FOR SELECT
  TO authenticated
  USING (
    (SELECT private.is_admin())
    OR status = 'published'
  );

COMMIT;
