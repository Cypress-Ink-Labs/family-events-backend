-- =============================================================================
-- Migration: Fix invites_required() default for Supabase Cloud
-- =============================================================================
--
-- Previous migrations tried to disable the invite gate by setting the
-- app.settings.require_invite GUC to 'false' via ALTER DATABASE / ALTER ROLE.
-- Supabase Cloud blocks both (insufficient_privilege), so the GUC remained
-- NULL and the function's coalesce(..., 'true') kept the gate ON.
--
-- This migration fixes the root cause: change the function's default from
-- 'true' to 'false' so that when the GUC is absent (NULL), the gate is OFF.
--
-- To re-enable the gate, set the GUC via the Supabase Dashboard SQL Editor:
--   ALTER ROLE postgres SET app.settings.require_invite = 'true';
-- =============================================================================

CREATE OR REPLACE FUNCTION "private"."invites_required"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'false')))
         IN ('true', 't', '1', 'yes');
$$;

COMMENT ON FUNCTION "private"."invites_required"()
  IS 'Returns true when invite gating is on. Defaults to false (open registration) when app.settings.require_invite is unset.';
