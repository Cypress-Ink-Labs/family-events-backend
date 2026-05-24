-- Tighten Supabase API exposure and remove unused GraphQL surface.
--
-- This migration keeps the app's REST/PostgREST paths working while removing
-- old broad table grants that made every public object GraphQL-discoverable.

DROP EXTENSION IF EXISTS pg_graphql;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM authenticated;

-- Anonymous users only need public read paths plus invite request RPCs.
GRANT SELECT ON TABLE
  public.cities,
  public.comments,
  public.event_rating_stats,
  public.event_tags,
  public.events,
  public.public_events,
  public.tags,
  public.timezone_names
TO anon;

-- Signed-in users need normal app reads, plus admin reads guarded by RLS.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;

-- Direct browser writes still used by non-admin product flows.
GRANT INSERT, UPDATE, DELETE ON TABLE public.comments TO authenticated;
GRANT INSERT, DELETE ON TABLE public.favorites TO authenticated;
GRANT INSERT, UPDATE, DELETE ON TABLE public.ratings TO authenticated;
GRANT INSERT, DELETE ON TABLE public.user_calendar_events TO authenticated;
GRANT UPDATE ON TABLE public.user_profiles TO authenticated;

-- Direct browser writes still used by admin screens; RLS keeps these admin-only.
GRANT INSERT, UPDATE ON TABLE public.cities TO authenticated;
GRANT DELETE ON TABLE public.invite_codes TO authenticated;

-- Keep sequence access available for direct inserts without restoring broad
-- table mutation grants.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Private tables are intentionally accessed through SECURITY DEFINER RPCs.
ALTER TABLE private.cron_enabled ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.railway_cron_runs ENABLE ROW LEVEL SECURITY;

-- Advisor proof: the project should not expose pg_graphql after this migration.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_graphql') THEN
    RAISE EXCEPTION 'pg_graphql extension is still installed';
  END IF;

END
$$;
