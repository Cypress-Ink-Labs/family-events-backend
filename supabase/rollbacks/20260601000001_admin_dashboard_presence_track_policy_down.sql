-- Rollback for 20260601000001_admin_dashboard_presence_track_policy.sql
-- The migration introduced the "Admins can track dashboard presence" INSERT policy
-- on realtime.messages. This migration is the source of that policy, so the down is
-- simply to drop it (no prior definition to restore).
DROP POLICY IF EXISTS "Admins can track dashboard presence" ON realtime.messages;
