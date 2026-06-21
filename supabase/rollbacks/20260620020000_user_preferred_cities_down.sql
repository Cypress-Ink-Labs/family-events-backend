-- Rollback for 20260620020000_user_preferred_cities.sql
-- Reverts:
--   - Drops RLS policies on public.user_preferred_cities
--   - Drops partial unique index user_preferred_cities_one_primary
--   - Drops table public.user_preferred_cities (DATA LOSS: all preferred-city
--     rows are permanently deleted; user_profiles.city_preference_id is unaffected)

BEGIN;

-- 1. Drop RLS policies.
DROP POLICY IF EXISTS user_preferred_cities_service_all
  ON public.user_preferred_cities;
DROP POLICY IF EXISTS user_preferred_cities_delete_own
  ON public.user_preferred_cities;
DROP POLICY IF EXISTS user_preferred_cities_update_own
  ON public.user_preferred_cities;
DROP POLICY IF EXISTS user_preferred_cities_insert_own
  ON public.user_preferred_cities;
DROP POLICY IF EXISTS user_preferred_cities_select_own
  ON public.user_preferred_cities;

-- 2. Revoke grants and drop table (index is dropped with the table).
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.user_preferred_cities FROM authenticated;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.user_preferred_cities FROM service_role;

DROP TABLE IF EXISTS public.user_preferred_cities;

COMMIT;
