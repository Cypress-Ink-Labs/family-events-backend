-- Advisor cleanup: public_events RLS leak, duplicate index, missing FK indexes.
-- ----------------------------------------------------------------
-- 1. public.public_events was a SECURITY DEFINER view, which bypasses the
--    caller's RLS on public.events. The intended behavior is "anyone can read
--    published events" — so we (a) flip the view to security_invoker = true
--    and (b) add a permissive anon+authenticated RLS policy on events for
--    status = 'published' so the same rows are visible through the view.
--    The existing authenticated/admin/access-gated policies stay; permissive
--    policies OR together, so admins still see drafts.
--
-- 2. Drop the redundant event_sources_url_idx — event_sources_url_key (unique)
--    already covers the same column.
--
-- 3. Add covering indexes for three foreign keys flagged by the advisor.
--    Without them, deletes/updates on the referenced parent rows do a seq
--    scan on the child table, and joins on the FK column don't get a useful
--    plan.

BEGIN;

-- =============================================
-- 1. public_events: switch to security_invoker + open published rows to anon
-- =============================================
ALTER VIEW public.public_events SET (security_invoker = true);

CREATE POLICY "Anyone can read published events"
  ON public.events
  FOR SELECT
  TO anon, authenticated
  USING (status = 'published');

-- =============================================
-- 2. Drop duplicate index on event_sources.url
-- =============================================
DROP INDEX IF EXISTS public.event_sources_url_idx;

-- =============================================
-- 3. Cover the three unindexed foreign keys
-- =============================================
CREATE INDEX IF NOT EXISTS event_tag_queue_source_run_id_idx
  ON public.event_tag_queue (source_run_id);

CREATE INDEX IF NOT EXISTS invite_requests_invite_code_id_idx
  ON public.invite_requests (invite_code_id);

CREATE INDEX IF NOT EXISTS invite_requests_reviewed_by_idx
  ON public.invite_requests (reviewed_by);

COMMIT;
