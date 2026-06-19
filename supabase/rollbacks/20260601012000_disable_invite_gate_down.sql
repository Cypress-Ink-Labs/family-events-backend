-- Rollback for 20260601012000_disable_invite_gate.sql
-- 012000 flipped private.invites_required()'s default from 'true' to 'false'
-- (open registration when app.settings.require_invite is unset) and updated its COMMENT.
-- This reverts the function body + comment to the pre-012000 definition, copied verbatim from
--   20260601000000_schema_baseline.sql:2705-2717 (default 'true').
-- CREATE OR REPLACE preserves owner + grants (unchanged since baseline), so none are re-emitted
-- (symmetric with the bare CREATE OR REPLACE in the UP migration).
--
-- NOTE: rolling this back restores closed-beta semantics (gate ON when the GUC is unset).
-- When reverting the whole invite-gate cluster, run the downs newest-first:
--   015000 -> 014000 -> 013000 -> 012000.

BEGIN;

CREATE OR REPLACE FUNCTION "private"."invites_required"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'true')))
         IN ('true', 't', '1', 'yes');
$$;

COMMENT ON FUNCTION "private"."invites_required"()
  IS 'Returns true when invite gating is on. Defaults to true when app.settings.require_invite is unset.';

COMMIT;
