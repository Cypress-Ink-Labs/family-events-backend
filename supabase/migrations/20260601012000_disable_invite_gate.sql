-- =============================================================================
-- Migration: Disable invite gate (open registration)
-- =============================================================================
--
-- Changes the invites_required() function to default to FALSE when the
-- app.settings.require_invite GUC is absent or unset.
--
-- Before: GUC absent → gate ON (closed beta)
-- After:  GUC absent → gate OFF (open registration)
--
-- This is Cloud-safe — it does not rely on ALTER DATABASE (which Supabase
-- Cloud blocks for custom GUCs). The gate can still be re-enabled by
-- setting the GUC to 'true' via the Dashboard SQL Editor:
--
--   ALTER ROLE postgres SET app.settings.require_invite = 'true';
--
-- Or session-level in tests:
--
--   SELECT set_config('app.settings.require_invite', 'true', false);
--
-- See: supabase/docs/INVITE_GATE.md
-- =============================================================================

-- Flip the default from 'true' to 'false'
CREATE OR REPLACE FUNCTION "private"."invites_required"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'false')))
         IN ('true', 't', '1', 'yes');
$$;

COMMENT ON FUNCTION "private"."invites_required"()
  IS 'Returns true when invite gating is on. Defaults to false (open registration) when app.settings.require_invite is unset.';
