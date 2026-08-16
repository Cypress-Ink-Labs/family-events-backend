-- Rollback for 20260816003000_clerk_user_mapping.sql
--
-- Drops the U19 identity mapping table. The mapping is reproducible by
-- re-running scripts/provision-clerk-users.mjs, but export the table first if
-- provisioning has already assigned Clerk accounts you want to keep aligned:
--
--   \copy (SELECT * FROM public.clerk_user_mapping) TO 'clerk_user_mapping_backup.csv' CSV HEADER

DROP TABLE public.clerk_user_mapping;
