-- Rollback for 20260601036000_admin_user_delete.sql
-- Reverts:
--   - DROP public.admin_delete_user(uuid)
--   - DROP private.admin_delete_user(uuid)

BEGIN;

-- 1. Drop public wrapper first (it calls the private function).
DROP FUNCTION IF EXISTS public.admin_delete_user(uuid);

-- 2. Drop private implementation.
DROP FUNCTION IF EXISTS private.admin_delete_user(uuid);

COMMIT;
