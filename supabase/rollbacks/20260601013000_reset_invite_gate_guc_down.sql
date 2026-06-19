-- Rollback for 20260601013000_reset_invite_gate_guc.sql
-- 013000 cleared any ROLE/DATABASE-level override of the app.settings.require_invite GUC
-- (ALTER ROLE/DATABASE ... RESET ...) so the invites_required() default would take effect.
--
-- IRREVERSIBLE (intentional no-op): a GUC RESET discards the prior override VALUE. Nothing records
-- what app.settings.require_invite was set to before 013000 ran (it may have been unset, 'true', or
-- 'false'), so a faithful rollback cannot restore it. We deliberately do NOT guess a value —
-- re-setting the GUC to a fabricated value would be worse than leaving it unset.
--
-- 013000 changed no schema objects, so there is nothing else to revert.
-- If you need invite gating ON after rolling back, set it explicitly per supabase/docs/INVITE_GATE.md:
--   ALTER ROLE postgres SET app.settings.require_invite = 'true';

BEGIN;
-- intentional no-op (GUC prior value is unknowable; see header)
COMMIT;
