BEGIN;

-- Explicitly revoke anon from admin-only functions (belt-and-suspenders;
-- 006900 already granted only to authenticated/service_role).
REVOKE ALL ON FUNCTION public.admin_set_cron_enabled(text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_cron_enabled(text, boolean) FROM anon;

-- Prevent future functions created in the public schema from being
-- automatically callable by PUBLIC.  Only affects functions created AFTER
-- this migration runs.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMIT;
