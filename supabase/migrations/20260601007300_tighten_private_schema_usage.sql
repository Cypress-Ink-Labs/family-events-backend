BEGIN;

-- Idempotent re-grant of USAGE on the private schema.
-- Ensures no accidental revoke has occurred since the original grants:
--   anon/authenticated: 20260601002200
--   service_role:       20260601005600_grant_private_schema_usage_service_role.sql
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

COMMIT;
