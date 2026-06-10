-- Rollback for 20260601026000_fix_unindexed_fk_admin_event_decisions.sql
-- Reverts:
--   - Drops index admin_event_decisions_admin_user_id_idx on
--     public.admin_event_decisions (admin_user_id)

BEGIN;

DROP INDEX IF EXISTS public.admin_event_decisions_admin_user_id_idx;

COMMIT;
