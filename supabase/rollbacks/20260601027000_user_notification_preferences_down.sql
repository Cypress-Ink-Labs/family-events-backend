-- Rollback for 20260601027000_user_notification_preferences.sql
-- Reverts:
--   - Drops GRANT on public.upsert_notification_preferences(boolean x6)
--   - Drops public.upsert_notification_preferences(boolean x6)
--   - Drops private.upsert_notification_preferences(boolean x6)
--   - Drops RLS policies on public.user_notification_preferences
--   - Drops table public.user_notification_preferences (DATA LOSS: all user
--     notification preference rows are permanently deleted)

BEGIN;

-- 1. Drop public RPC grants and function.
REVOKE ALL ON FUNCTION public.upsert_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean)
  FROM authenticated, service_role;

DROP FUNCTION IF EXISTS public.upsert_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean);

-- 2. Drop private body.
DROP FUNCTION IF EXISTS private.upsert_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean);

-- 3. Drop RLS policies.
DROP POLICY IF EXISTS user_notification_preferences_service_all
  ON public.user_notification_preferences;
DROP POLICY IF EXISTS user_notification_preferences_update_own
  ON public.user_notification_preferences;
DROP POLICY IF EXISTS user_notification_preferences_insert_own
  ON public.user_notification_preferences;
DROP POLICY IF EXISTS user_notification_preferences_select_own
  ON public.user_notification_preferences;

-- 4. Revoke grants and drop table (DATA LOSS: all preference rows deleted).
REVOKE SELECT, INSERT, UPDATE ON public.user_notification_preferences FROM authenticated;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.user_notification_preferences FROM service_role;

DROP TABLE IF EXISTS public.user_notification_preferences;

COMMIT;
