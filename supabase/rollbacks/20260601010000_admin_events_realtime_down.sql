-- Rollback for 20260601010000_admin_events_realtime.sql
-- The migration introduced the events broadcast trigger + its function and the
-- dashboard-realtime SELECT policy on realtime.messages. All three originate here,
-- so the down drops them (nothing prior to restore). Drop the trigger before the
-- function it depends on.
BEGIN;

DROP TRIGGER IF EXISTS broadcast_admin_event_changes_trigger ON public.events;
DROP FUNCTION IF EXISTS private.broadcast_admin_event_changes();
DROP POLICY IF EXISTS "Admins can receive dashboard realtime" ON realtime.messages;

COMMIT;
