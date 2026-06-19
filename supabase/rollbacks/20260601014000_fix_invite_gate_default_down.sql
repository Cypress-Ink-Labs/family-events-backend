-- Rollback for 20260601014000_fix_invite_gate_default.sql
-- 014000 re-asserted private.invites_required()'s default = 'false'. This is IDENTICAL to the state
-- already established by 20260601012000 (014000 duplicated it as a Supabase-Cloud belt-and-suspenders).
-- The state immediately BEFORE 014000 ran was therefore already "default 'false'", so this rollback
-- restores that exact body (effectively a no-op re-apply, kept for determinism and ordering safety).
--   prior body == post-012000 body (default 'false'); see 20260601012000_disable_invite_gate.sql.
--
-- The real flip back to baseline 'true' happens in 20260601012000_disable_invite_gate_down.sql.
-- When reverting the cluster, run the downs newest-first: 015000 -> 014000 -> 013000 -> 012000.

BEGIN;

CREATE OR REPLACE FUNCTION "private"."invites_required"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'false')))
         IN ('true', 't', '1', 'yes');
$$;

COMMENT ON FUNCTION "private"."invites_required"()
  IS 'Returns true when invite gating is on. Defaults to false (open registration) when app.settings.require_invite is unset.';

COMMIT;
