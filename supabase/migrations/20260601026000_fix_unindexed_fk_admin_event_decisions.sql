-- ============================================================================
-- Fix: Unindexed foreign key on admin_event_decisions.admin_user_id
-- ============================================================================
-- Addresses Supabase performance advisor lint:
--   "Unindexed foreign keys"
--   Table `public.admin_event_decisions` has a foreign key
--   `admin_event_decisions_admin_user_id_fkey` without a covering index.
--
-- This FK references auth.users(id) (ON DELETE SET NULL).
-- Without an index, Postgres must perform a sequential scan on this table
-- during RI checks when an auth.users row is updated/deleted (rare but
-- possible), and it prevents efficient queries/joins on admin_user_id.
--
-- Precedent: same pattern used for ai_feature_config.model_id and .updated_by
-- in 20260601006000_...
--
-- Note: The JS validator in scripts/ and the table creation migration
-- (20260601021000) are the source of truth for expected schema. This is a
-- targeted performance fix only.
-- ============================================================================

BEGIN;

-- Add plain covering btree index on the FK column.
-- Name follows existing convention: <table>_<column>_idx
CREATE INDEX IF NOT EXISTS admin_event_decisions_admin_user_id_idx
  ON public.admin_event_decisions (admin_user_id);

COMMENT ON INDEX public.admin_event_decisions_admin_user_id_idx IS
  'Covering index for FK admin_event_decisions_admin_user_id_fkey to auth.users(id). '
  'Required by Supabase performance advisors for efficient referential integrity '
  'and any future filtering/grouping by the acting admin.';

COMMIT;
