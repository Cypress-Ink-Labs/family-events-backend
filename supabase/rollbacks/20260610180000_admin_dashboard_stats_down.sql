-- Rollback for 20260610180000_admin_dashboard_stats.sql
--   Drops public.admin_dashboard_stats() and private.admin_dashboard_stats().
--   No data loss — function-only migration. The admin dashboard falls back to
--   erroring on its stats card until the web client is reverted as well.

BEGIN;

DROP FUNCTION IF EXISTS public.admin_dashboard_stats();
DROP FUNCTION IF EXISTS private.admin_dashboard_stats();

COMMIT;
