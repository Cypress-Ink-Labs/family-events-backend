-- ============================================================================
-- CIL-19 Phase 1: Multi-city user preferences (schema + backfill)
-- ============================================================================
-- Adds public.user_preferred_cities so users can store multiple preferred
-- cities. The existing user_profiles.city_preference_id is NOT altered —
-- it remains as the single-city compatibility column until the frontend
-- completes the UX migration (Phase 2).
--
-- Backfills all users that currently have a city_preference_id set so that
-- single-city users keep working transparently.
--
-- Paired rollback:
-- supabase/rollbacks/20260620020000_user_preferred_cities_down.sql
-- ============================================================================

BEGIN;

-- ─── Table ───────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_preferred_cities (
  user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  city_id     uuid        NOT NULL REFERENCES public.cities(id) ON DELETE CASCADE,
  is_primary  boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, city_id)
);

COMMENT ON TABLE public.user_preferred_cities IS
  'Per-user set of preferred cities. Populated from user_profiles.city_preference_id '
  'via backfill; multi-city UX (Phase 2) will write here directly. The is_primary '
  'flag is enforced unique-per-user by a partial unique index.';

-- ─── Indexes ─────────────────────────────────────────────────────────────────

-- The composite PK (user_id, city_id) already covers per-user lookups via the
-- leading column, so no additional plain index on user_id is needed.

-- At most one primary city per user.
CREATE UNIQUE INDEX user_preferred_cities_one_primary
  ON public.user_preferred_cities (user_id)
  WHERE is_primary;

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.user_preferred_cities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_preferred_cities FORCE ROW LEVEL SECURITY;

CREATE POLICY user_preferred_cities_select_own
  ON public.user_preferred_cities
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY user_preferred_cities_insert_own
  ON public.user_preferred_cities
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY user_preferred_cities_update_own
  ON public.user_preferred_cities
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY user_preferred_cities_delete_own
  ON public.user_preferred_cities
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- Service role full access (for edge functions / cron / backfill).
CREATE POLICY user_preferred_cities_service_all
  ON public.user_preferred_cities
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ─── Grants ──────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_preferred_cities TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_preferred_cities TO service_role;

-- ─── Backfill ────────────────────────────────────────────────────────────────
-- Copy every existing city_preference_id into the new table as a primary city.
-- ON CONFLICT DO NOTHING makes this idempotent if re-run.
-- FK-safe: user_profiles.city_preference_id has no enforced FK to cities, so
-- prod can hold orphaned references (a deleted city). Skip those — they'd
-- violate user_preferred_cities_city_id_fkey.

INSERT INTO public.user_preferred_cities (user_id, city_id, is_primary)
SELECT id, city_preference_id, true
FROM public.user_profiles
WHERE city_preference_id IS NOT NULL
  AND city_preference_id IN (SELECT id FROM public.cities)
ON CONFLICT (user_id, city_id) DO NOTHING;

COMMIT;
