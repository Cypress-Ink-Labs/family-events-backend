-- =============================================================================
-- Migration: Disable invite gate for local development
-- =============================================================================
--
-- This sets app.settings.require_invite to 'false' at the database level so
-- local dev starts with open registration (no invite code required).
--
-- Production toggle:
--   The invite gate in production is managed manually via the Supabase SQL
--   Editor or Dashboard. See supabase/docs/INVITE_GATE.md for the full
--   runbook.
--
-- To re-enable locally:
--   ALTER DATABASE postgres SET app.settings.require_invite = 'true';
--
-- Note: Session-level set_config() (used in tests) overrides this database-
-- level default, so existing tests are unaffected.
-- =============================================================================

ALTER DATABASE postgres SET app.settings.require_invite = 'false';
