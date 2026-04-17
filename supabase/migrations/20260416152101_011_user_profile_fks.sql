/*
  # Fix user_id FK to point at user_profiles, not auth.users

  PostgREST resolves joins via FK constraints. All user-owned tables had:
    user_id → auth.users(id)   ← in the auth schema, invisible to PostgREST

  Admin queries use patterns like:
    ratings.select("*, user_profiles(display_name)")

  PostgREST can't traverse auth.users to user_profiles, so it throws
  PGRST202 "Could not find a relationship".

  Fix: drop the auth.users FK and add a new one to public.user_profiles(id).
  Both columns hold the same UUID (Supabase guarantees user_profiles.id =
  auth.users.id), so no data is affected. CASCADE behaviour preserved.
*/

-- ratings
ALTER TABLE public.ratings DROP CONSTRAINT IF EXISTS ratings_user_id_fkey;
ALTER TABLE public.ratings
  ADD CONSTRAINT ratings_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;

-- comments
ALTER TABLE public.comments DROP CONSTRAINT IF EXISTS comments_user_id_fkey;
ALTER TABLE public.comments
  ADD CONSTRAINT comments_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;

-- favorites
ALTER TABLE public.favorites DROP CONSTRAINT IF EXISTS favorites_user_id_fkey;
ALTER TABLE public.favorites
  ADD CONSTRAINT favorites_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;

-- user_calendar_events
ALTER TABLE public.user_calendar_events DROP CONSTRAINT IF EXISTS user_calendar_events_user_id_fkey;
ALTER TABLE public.user_calendar_events
  ADD CONSTRAINT user_calendar_events_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;

-- recommendation_signals
ALTER TABLE public.recommendation_signals DROP CONSTRAINT IF EXISTS recommendation_signals_user_id_fkey;
ALTER TABLE public.recommendation_signals
  ADD CONSTRAINT recommendation_signals_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;
