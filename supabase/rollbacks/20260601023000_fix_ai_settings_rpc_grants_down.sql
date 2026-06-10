-- Rollback for 20260601023000_fix_ai_settings_rpc_grants.sql
-- Reverts:
--   - GRANT EXECUTE on private.upsert_ai_feature_config to authenticated, service_role
-- Restores the pre-023000 grant state: private fn is service_role only.
-- Prior grant state sourced from 20260601005000_ai_models_and_cron_drilldown.sql
-- (final block, lines 343-346): service_role only on private wrapper.
-- Data-loss caveat: none — grant-only change.

BEGIN;

REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  FROM authenticated;

-- Ensure service_role still has access (it did before 023000).
GRANT EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  TO service_role;

COMMIT;
