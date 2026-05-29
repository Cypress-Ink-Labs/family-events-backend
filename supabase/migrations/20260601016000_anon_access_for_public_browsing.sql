-- =============================================================================
-- Migration: Grant anon access for public event browsing
-- =============================================================================
--
-- The events_enriched() function LEFT JOINs favorites, user_calendar_events,
-- and ratings. PostgreSQL checks table-level privileges on JOIN targets even
-- when the join condition short-circuits (p_user_id IS NOT NULL).
--
-- This grants anon SELECT on those tables so the function works for
-- unauthenticated users. RLS policies control row visibility:
-- - favorites: anon sees no rows (USING false)
-- - user_calendar_events: anon sees no rows (USING false)
-- - ratings: existing policy scopes to published events
-- =============================================================================

-- favorites: grant + deny-all RLS policy
GRANT SELECT ON public.favorites TO anon;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'favorites'
      AND policyname = 'Anon sees no favorites'
  ) THEN
    CREATE POLICY "Anon sees no favorites"
      ON public.favorites FOR SELECT TO anon
      USING (false);
  END IF;
END;
$$;

-- user_calendar_events: grant + deny-all RLS policy
GRANT SELECT ON public.user_calendar_events TO anon;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'user_calendar_events'
      AND policyname = 'Anon sees no calendar events'
  ) THEN
    CREATE POLICY "Anon sees no calendar events"
      ON public.user_calendar_events FOR SELECT TO anon
      USING (false);
  END IF;
END;
$$;

-- ratings: grant only (RLS policy "Anon can read ratings for published events" already exists)
GRANT SELECT ON public.ratings TO anon;
